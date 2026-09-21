import Foundation

// MARK: - Transport shapes
//
// These mirror the Google Reader API's JSON exactly. They exist only to be
// decoded; nothing above this file sees them.
//
// Decoding is deliberately defensive: the API omits fields that it considers
// empty (a feed with no summary has no `summary` key at all), and a strict
// `Decodable` conformance would fail the whole response over one absent key.

struct UnreadCountsResponse: Decodable, Sendable {
    let unreadcounts: [UnreadCountEntry]
}

struct UnreadCountEntry: Decodable, Sendable {
    let id: String
    let count: Int

    private enum CodingKeys: String, CodingKey { case id, count }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
}

struct StreamResponse: Decodable, Sendable {
    let items: [StreamItem]?

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try? c.decode([StreamItem].self, forKey: .items)
    }
}

struct StreamItem: Decodable, Sendable {
    let id: String
    let title: String?
    let published: Double?
    let canonical: [CanonicalLink]?
    let origin: Origin?
    let summary: Summary?

    struct CanonicalLink: Decodable, Sendable { let href: String? }
    struct Origin: Decodable, Sendable {
        let streamId: String?
        let title: String?
    }
    struct Summary: Decodable, Sendable { let content: String? }

    private enum CodingKeys: String, CodingKey {
        case id, title, published, canonical, origin, summary
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = try? c.decode(String.self, forKey: .title)
        published = try? c.decode(Double.self, forKey: .published)
        canonical = try? c.decode([CanonicalLink].self, forKey: .canonical)
        origin = try? c.decode(Origin.self, forKey: .origin)
        summary = try? c.decode(Summary.self, forKey: .summary)
    }

    /// Flatten into the UI's model.
    func toArticle() -> Article {
        Article(
            id: id,
            title: title ?? "",
            url: canonical?.first?.href.flatMap(URL.init(string:)),
            published: Date(timeIntervalSince1970: published ?? 0),
            feedTitle: origin?.title ?? "Unknown feed",
            feedId: origin?.streamId ?? "",
            summary: (summary?.content ?? "").strippedHTML.collapsedWhitespace
        )
    }
}

// MARK: - API client

/// Client for FreshRSS's Google Reader compatible API.
///
/// An actor because it holds mutable auth state that must not be raced: the
/// status bar timer can fire a refresh while a settings change is rebuilding the
/// client, and two simultaneous logins would invalidate each other's tokens.
///
/// Endpoint reference: https://freshrss.github.io/FreshRSS/en/developers/06_GoogleReader_API.html
actor FreshRSSAPI {

    struct Credentials: Sendable, Equatable {
        var baseURL: URL
        var user: String
        var password: String
    }

    /// The read state marker used by the Google Reader API.
    private static let readState = "user/-/state/com.google/read"
    private static let readingList = "user/-/state/com.google/reading-list"
    private static let labelPrefix = "user/-/label/"

    private let session: URLSession
    private var credentials: Credentials?
    private var authToken: String?
    private var writeToken: String?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 25
        // Must be false. With it on, a stopped Docker daemon produces a long
        // hang instead of the immediate "stack is down" the user should see.
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    // MARK: Configuration

    func configure(_ credentials: Credentials?) {
        // Only invalidate cached tokens when something actually changed;
        // otherwise every refresh would force a redundant login.
        if self.credentials != credentials {
            self.credentials = credentials
            authToken = nil
            writeToken = nil
        }
    }

    var isConfigured: Bool {
        guard let c = credentials else { return false }
        return !c.user.isEmpty && !c.password.isEmpty
    }

    // MARK: Public operations

    /// Verify credentials end-to-end. Used by the Settings "Test" button.
    func verifyConnection() async throws {
        _ = try await requireAuth()
    }

    /// Total unread, per-category counts, and per-feed counts in one call.
    func unreadCounts() async throws -> (total: Int, categories: [CategoryCount], feeds: [FeedCount]) {
        let data = try await authorized(
            path: "/reader/api/0/unread-count",
            query: [URLQueryItem(name: "output", value: "json")]
        )
        let response = try decode(UnreadCountsResponse.self, from: data)

        var total = 0
        var categories: [CategoryCount] = []
        var feeds: [FeedCount] = []

        for entry in response.unreadcounts {
            if entry.id == Self.readingList {
                total = entry.count
            } else if entry.id.hasPrefix(Self.labelPrefix) {
                let name = String(entry.id.dropFirst(Self.labelPrefix.count))
                categories.append(CategoryCount(id: entry.id, name: name, unread: entry.count))
            } else if entry.id.hasPrefix("feed/") {
                let url = String(entry.id.dropFirst("feed/".count))
                feeds.append(FeedCount(id: entry.id, title: url, unread: entry.count))
            }
        }

        categories.sort { $0.unread > $1.unread }
        feeds.sort { $0.unread > $1.unread }
        return (total, categories, feeds)
    }

    /// The newest unread articles across all feeds.
    func unreadArticles(limit: Int = 50) async throws -> [Article] {
        let data = try await authorized(
            path: "/reader/api/0/stream/contents/reading-list",
            query: [
                // `xt` EXCLUDES a state; this asks for everything not yet read.
                URLQueryItem(name: "xt", value: Self.readState),
                URLQueryItem(name: "n", value: String(limit)),
                URLQueryItem(name: "output", value: "json"),
            ]
        )
        let response = try decode(StreamResponse.self, from: data)
        return (response.items ?? []).map { $0.toArticle() }
    }

    /// Map feed ids to human titles, so the article list can show a feed name.
    func feedTitles() async throws -> [String: String] {
        let data = try await authorized(
            path: "/reader/api/0/subscription/list",
            query: [URLQueryItem(name: "output", value: "json")]
        )
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subs = root["subscriptions"] as? [[String: Any]] else {
            return [:]
        }
        var titles: [String: String] = [:]
        for sub in subs {
            guard let id = sub["id"] as? String else { continue }
            titles[id] = (sub["title"] as? String) ?? id
        }
        return titles
    }

    /// Mark specific articles read.
    func markRead(itemIds: [String]) async throws {
        guard !itemIds.isEmpty else { return }
        let token = try await requireWriteToken()
        for id in itemIds {
            _ = try await authorized(
                path: "/reader/api/0/edit-tag",
                method: "POST",
                body: formEncoded([
                    ("a", Self.readState),
                    ("i", id),
                    ("T", token),
                ])
            )
        }
    }

    /// Mark everything currently unread as read.
    ///
    /// The API takes a stream id for this rather than individual items, so it is
    /// one request instead of one per article.
    func markAllRead() async throws {
        let token = try await requireWriteToken()
        _ = try await authorized(
            path: "/reader/api/0/mark-all-as-read",
            method: "POST",
            body: formEncoded([
                ("s", Self.readingList),
                ("ts", String(Int(Date().timeIntervalSince1970 * 1_000_000))),
                ("T", token),
            ])
        )
    }

    // MARK: Auth

    private func requireAuth() async throws -> String {
        if let authToken { return authToken }
        return try await authenticate()
    }

    /// `POST /accounts/ClientLogin` -> a body containing `Auth=user/token`.
    @discardableResult
    private func authenticate() async throws -> String {
        guard let credentials else { throw FreshRSSError.notConfigured }

        let url = try makeURL("/accounts/ClientLogin")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            ("Email", credentials.user),
            ("Passwd", credentials.password),
        ])

        let (data, response) = try await perform(request)

        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw FreshRSSError.unauthorized
        case 503:
            // FreshRSS returns 503 here specifically when the Authentication
            // toggle is off. It is the most likely failure on a fresh install
            // and deserves its own state so the fix is obvious.
            throw FreshRSSError.apiDisabled
        default:
            throw FreshRSSError.http(response.statusCode)
        }

        guard let body = String(data: data, encoding: .utf8) else {
            throw FreshRSSError.decoding("login response was not text")
        }

        // The body is newline-separated key=value pairs. `Auth=` is the one we want.
        for line in body.split(separator: "\n") where line.hasPrefix("Auth=") {
            let token = String(line.dropFirst("Auth=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { break }
            authToken = token
            return token
        }

        // A 200 with no Auth= line means the password was wrong but the server
        // chose not to say so with a status code.
        throw FreshRSSError.unauthorized
    }

    private func requireWriteToken() async throws -> String {
        if let writeToken { return writeToken }
        let data = try await authorized(path: "/reader/api/0/token")
        guard let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw FreshRSSError.decoding("empty write token")
        }
        writeToken = token
        return token
    }

    // MARK: Request plumbing

    /// An authenticated GET/POST that re-authenticates exactly once on a 401.
    @discardableResult
    private func authorized(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        var token = try await requireAuth()

        func build(_ authToken: String) throws -> URLRequest {
            let url = try makeURL(path, query: query)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("GoogleLogin auth=\(authToken)", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
            return request
        }

        var (data, response) = try await perform(try build(token))

        if response.statusCode == 401 {
            // Token expired server-side (password changed, session evicted, or
            // the instance restarted). Re-authenticate once, then give up.
            authToken = nil
            writeToken = nil
            token = try await authenticate()
            (data, response) = try await perform(try build(token))
        }

        switch response.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw FreshRSSError.unauthorized
        case 503:
            throw FreshRSSError.apiDisabled
        default:
            throw FreshRSSError.http(response.statusCode)
        }
    }

    /// Runs a request and maps transport failures into `FreshRSSError`.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FreshRSSError.unreachable("non-HTTP response")
            }
            return (data, http)
        } catch let error as FreshRSSError {
            throw error
        } catch let error as URLError {
            switch error.code {
            // There is no `.connectionRefused` case. A refused connection on a
            // loopback address surfaces as `.cannotConnectToHost`, which is the
            // single most common failure here (Docker is not running).
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed:
                throw FreshRSSError.unreachable("connection refused")
            case .timedOut:
                throw FreshRSSError.unreachable("timed out")
            case .notConnectedToInternet:
                throw FreshRSSError.unreachable("no network")
            default:
                throw FreshRSSError.unreachable(error.localizedDescription)
            }
        } catch {
            throw FreshRSSError.unreachable(error.localizedDescription)
        }
    }

    private func makeURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let base = credentials?.baseURL else { throw FreshRSSError.notConfigured }
        var raw = base.absoluteString
        while raw.hasSuffix("/") { raw.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard var comps = URLComponents(string: raw + suffix) else {
            throw FreshRSSError.invalidURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw FreshRSSError.invalidURL }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FreshRSSError.decoding(error.localizedDescription)
        }
    }

    /// Percent-encodes key/value pairs as `application/x-www-form-urlencoded`.
    private func formEncoded(_ pairs: [(String, String)]) -> Data {
        var comps = URLComponents()
        comps.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }
}
