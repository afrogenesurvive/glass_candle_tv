import Foundation
import Observation
import AppKit

/// App state: connection status, unread snapshot, article list.
///
/// This is the only mutable state the UI observes. Views never talk to
/// `FreshRSSAPI` directly — it is an actor, and the UI is not, so a direct call
/// from a view would put `await` in places that cannot handle it.
@MainActor
@Observable
final class FreshRSSClient {

    // MARK: Published state

    private(set) var status: ConnectionStatus = .unconfigured
    private(set) var snapshot: UnreadSnapshot = .empty
    private(set) var articles: [Article] = []
    private(set) var feedCounts: [FeedCount] = []
    private(set) var bridge: BridgeHealthCheck.State = .unknown
    private(set) var lastRefresh: Date?
    private(set) var isConfigured = false
    /// True while a *user-initiated* refresh runs, so the popover can show a
    /// spinner without flickering on every background poll.
    private(set) var isManualRefresh = false

    // MARK: Private

    private let api = FreshRSSAPI()
    private let prefs = PrefsStore.shared
    private var feedTitles: [String: String] = [:]
    private var feedTitlesFetchedAt: Date?

    /// Feed titles are stable for hours; refetching them every poll would triple
    /// the request count for no benefit.
    private let feedTitleTTL: TimeInterval = 3600
    /// Upper bound on articles held in memory. The menu bar shows a summary, not
    /// an archive.
    private let articleLimit = 60

    init() {}

    // MARK: Derived

    /// Unread pressure as a flame, for the menu bar indicator.
    ///
    /// Note this is NOT purely a function of the unread count: a rejected
    /// password is a state you need to notice, so it shows amber rather than the
    /// grey of "no data".
    var flameLevel: FlameLevel {
        switch status {
        case .unconfigured, .unreachable:
            return .down
        case .unauthorized, .apiDisabled:
            return .moderate
        case .ok, .idle, .refreshing:
            return FlameLevel.forUnread(snapshot.total)
        }
    }

    var menuBarText: String {
        switch prefs.menuBarTextMode {
        case .off:
            return ""
        case .unread:
            guard status.isConnected else { return "—" }
            return "\(snapshot.total)"
        case .unreadOfTotal:
            guard status.isConnected else { return "—" }
            return "\(snapshot.total)"
        }
    }

    var relativeLastRefresh: String {
        guard let lastRefresh else { return "never" }
        let seconds = Int(Date().timeIntervalSince(lastRefresh))
        switch seconds {
        case ..<10:    return "just now"
        case ..<60:    return "\(seconds)s ago"
        case ..<3600:  return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default:       return "\(seconds / 86400)d ago"
        }
    }

    // MARK: Configuration

    /// Rebuild the API credentials from prefs + Keychain.
    ///
    /// Safe to call repeatedly: `FreshRSSAPI.configure` only drops cached tokens
    /// when the credentials actually changed, so a no-op reconfigure does not
    /// force a fresh login on the next poll.
    func reconfigure() async {
        let password = KeychainStore.load() ?? ""

        guard let url = prefs.apiURL,
              !prefs.apiUser.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty else {
            await api.configure(nil)
            isConfigured = false
            status = .unconfigured
            snapshot = .empty
            articles = []
            feedCounts = []
            return
        }

        await api.configure(
            FreshRSSAPI.Credentials(baseURL: url, user: prefs.apiUser, password: password)
        )
        isConfigured = true
    }

    /// Validate credentials without disturbing the article list. Used by the
    /// Settings "Test connection" button.
    func testConnection() async -> Result<Void, FreshRSSError> {
        do {
            try await api.verifyConnection()
            return .success(())
        } catch let error as FreshRSSError {
            return .failure(error)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    // MARK: Refresh

    func refresh(manual: Bool = false) async {
        guard isConfigured else {
            status = .unconfigured
            return
        }

        if manual { isManualRefresh = true }
        defer { if manual { isManualRefresh = false } }

        // Only show the transient "refreshing" state for a manual refresh.
        // Flipping it on every background poll makes the header flicker.
        if manual { status = .refreshing }

        do {
            let counts = try await api.unreadCounts()
            let items = try await api.unreadArticles(limit: articleLimit)

            if manual || feedTitles.isEmpty { await refreshFeedTitlesIfStale() }

            snapshot = UnreadSnapshot(
                total: counts.total,
                categories: counts.categories,
                updatedAt: Date()
            )

            feedCounts = counts.feeds.map { feed in
                FeedCount(
                    id: feed.id,
                    title: feedTitles[feed.id] ?? Self.hostLabel(feed.title),
                    unread: feed.unread
                )
            }

            articles = items
            lastRefresh = Date()
            status = .ok
        } catch let error as FreshRSSError {
            // Deliberately keep the previous snapshot and articles. Stale data
            // plus an error banner is more useful than an empty window, and it
            // makes a brief outage invisible instead of alarming.
            status = error.status
        } catch {
            status = .unreachable(error.localizedDescription)
        }

        await refreshBridgeState()
    }

    func markAllRead() async {
        do {
            try await api.markAllRead()
            await refresh(manual: true)
        } catch let error as FreshRSSError {
            status = error.status
        } catch {
            status = .unreachable(error.localizedDescription)
        }
    }

    func markRead(_ article: Article) async {
        do {
            try await api.markRead(itemIds: [article.id])
            articles.removeAll { $0.id == article.id }
            snapshot.total = max(0, snapshot.total - 1)
        } catch let error as FreshRSSError {
            status = error.status
        } catch {
            status = .unreachable(error.localizedDescription)
        }
    }

    // MARK: Helpers

    private func refreshFeedTitlesIfStale() async {
        if let fetchedAt = feedTitlesFetchedAt,
           Date().timeIntervalSince(fetchedAt) < feedTitleTTL,
           !feedTitles.isEmpty {
            return
        }
        if let titles = try? await api.feedTitles() {
            feedTitles = titles
            feedTitlesFetchedAt = Date()
        }
    }

    private func refreshBridgeState() async {
        bridge = await BridgeHealthCheck.probe(prefs.rssBridgeEndpoint)
    }

    /// Turn `https://example.com/blog/feed` into `example.com` — better than
    /// showing a raw URL when a feed has no title.
    private static func hostLabel(_ raw: String) -> String {
        URL(string: raw)?.host ?? raw
    }

    // MARK: Actions

    func openWebUI() {
        guard let url = prefs.webUIURL else { return }
        NSWorkspace.shared.open(url)
    }

    func open(_ article: Article) {
        guard let url = article.url else { return }
        NSWorkspace.shared.open(url)
    }

    func openSettingsWindow() {
        StatusBarController.shared.showSettings()
    }
}
