import Foundation

/// Lightweight reachability probe for the RSS-Bridge service.
///
/// This is a *liveness* check, not a per-source health check. It answers one
/// question: "is the bridge host up at all?" That is worth showing because the
/// two failure modes look identical in the article list —
///
///   - the bridge service is down, so every bridged feed is silently empty
///   - nothing new was published
///
/// — and they need completely different responses from the user.
struct BridgeHealthCheck: Sendable {

    enum State: Sendable, Equatable {
        case unknown
        case up
        case down
        /// No bridge URL configured; nothing to check.
        case notConfigured

        var label: String {
            switch self {
            case .unknown:       return "RSS-Bridge unknown"
            case .up:            return "RSS-Bridge up"
            case .down:          return "RSS-Bridge down"
            case .notConfigured: return "RSS-Bridge not configured"
            }
        }
    }

    /// A short timeout is correct here: this is a courtesy indicator, and a
    /// hanging probe would stall the refresh that the user actually asked for.
    static func probe(_ url: URL?) async -> State {
        guard let url, !url.absoluteString.isEmpty else { return .notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .down }
            // Any HTTP answer proves something is listening. A 403 from token
            // auth is a *healthy* bridge.
            return (200...499).contains(http.statusCode) ? .up : .down
        } catch {
            return .down
        }
    }
}
