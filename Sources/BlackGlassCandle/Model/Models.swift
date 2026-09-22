import Foundation

// MARK: - Articles

/// One unread article, in the shape the UI needs.
///
/// Flattened from the Google Reader API's nested JSON (see `FreshRSSAPI`) so that
/// everything above the network layer deals with plain values.
struct Article: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let url: URL?
    let published: Date
    let feedTitle: String
    let feedId: String
    let summary: String

    /// Fallback shown when a feed supplies no title at all. Better than an empty
    /// row that looks like a rendering bug.
    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(untitled)"
            : title
    }
}

// MARK: - Unread accounting

/// Per-category unread total, derived from `user/-/label/<name>` entries.
struct CategoryCount: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let unread: Int
}

/// Per-feed unread total, derived from `feed/<url>` entries.
struct FeedCount: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let unread: Int
}

/// A complete picture of unread state at one moment.
struct UnreadSnapshot: Sendable, Equatable {
    var total: Int = 0
    var categories: [CategoryCount] = []
    var updatedAt: Date = .distantPast

    static let empty = UnreadSnapshot()
}

// MARK: - Menu bar presentation

/// How the menu bar renders the unread count.
enum MenuBarTextMode: String, CaseIterable, Sendable, Identifiable {
    case unread
    case unreadOfTotal
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unread:         return "Unread count"
        case .unreadOfTotal:  return "Unread / total"
        case .off:            return "Icon only"
        }
    }
}

/// Unread pressure, expressed as a flame. Drives the menu bar indicator colour.
///
/// The thresholds are arbitrary but deliberate: 0 means caught up, and anything
/// past ~40 stops being a count and starts being a backlog.
enum FlameLevel: Int, Sendable, CaseIterable {
    case down     = 0   // stack unreachable
    case clear    = 1   // 0 unread
    case low      = 2   // 1...10
    case moderate = 3   // 11...40
    case high     = 4   // 41+

    static func forUnread(_ count: Int) -> FlameLevel {
        switch count {
        case ..<1:   return .clear
        case 1...10: return .low
        case 11...40: return .moderate
        default:     return .high
        }
    }

    var caption: String {
        switch self {
        case .down:     return "unreachable"
        case .clear:    return "caught up"
        case .low:      return "a few"
        case .moderate: return "backlog"
        case .high:     return "pile-up"
        }
    }
}

// MARK: - Connection status

/// The connection state machine.
///
/// Each case is distinct because each one has a *different fix*. Collapsing them
/// into a single "error" would leave the user staring at a grey candle with no
/// idea whether to start the services (`./scripts/services.sh start`) or change
/// a password.
enum ConnectionStatus: Sendable, Equatable {
    case unconfigured
    case idle
    case refreshing
    case ok
    case unreachable(String)
    case unauthorized
    /// FreshRSS answered 503: the "Allow API access" toggle is off.
    case apiDisabled

    var isConnected: Bool {
        switch self {
        case .ok, .refreshing: return true
        default: return false
        }
    }

    /// Short label for the popover header.
    var label: String {
        switch self {
        case .unconfigured:     return "Not configured"
        case .idle:             return "Idle"
        case .refreshing:       return "Refreshing"
        case .ok:               return "Connected"
        case .unreachable:      return "Stack unreachable"
        case .unauthorized:     return "Password rejected"
        case .apiDisabled:      return "API access is off"
        }
    }

    /// The concrete next step. Shown under the header when something is wrong.
    var remedy: String? {
        switch self {
        case .unreachable:
            // Also reached when a response fails to decode, so this points at
            // the stack rather than claiming the network is down.
            return "Check the stack:  ./scripts/services.sh status"
        case .unauthorized:
            return "Check the API password, then re-run scripts/seed_menubar_config.sh"
        case .apiDisabled:
            return "In FreshRSS: Authentication -> enable \"Allow API access\""
        case .unconfigured:
            return "Settings -> enter your API password"
        case .ok, .idle, .refreshing:
            return nil
        }
    }
}

// MARK: - Errors

enum FreshRSSError: LocalizedError, Sendable {
    case notConfigured
    case invalidURL
    case unreachable(String)
    case unauthorized
    case apiDisabled
    case http(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return "No API credentials configured."
        case .invalidURL:           return "The API base URL is not a valid URL."
        case .unreachable(let why): return "Cannot reach the stack: \(why)"
        case .unauthorized:         return "The API password was rejected."
        case .apiDisabled:          return "API access is disabled in FreshRSS."
        case .http(let code):       return "The server returned HTTP \(code)."
        case .decoding(let why):    return "Could not read the response: \(why)"
        }
    }

    /// Collapse a thrown error into the UI state that fixes it.
    var status: ConnectionStatus {
        switch self {
        case .notConfigured:        return .unconfigured
        case .unauthorized:         return .unauthorized
        case .apiDisabled:          return .apiDisabled
        case .unreachable(let why): return .unreachable(why)
        case .invalidURL:           return .unreachable("invalid URL")
        case .http(let code):       return .unreachable("HTTP \(code)")
        case .decoding(let why):    return .unreachable("bad response (\(why))")
        }
    }
}

// MARK: - Helpers

extension String {
    /// Minimal HTML-to-text for feed summaries.
    ///
    /// A full parser is not worth a dependency here: feed summaries are short and
    /// the tag set is small. Handles the named entities that actually show up.
    var strippedHTML: String {
        var out = ""
        var insideTag = false
        for ch in self {
            if ch == "<" { insideTag = true; continue }
            if ch == ">" { insideTag = false; continue }
            if !insideTag { out.append(ch) }
        }
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&hellip;", "..."),
        ]
        for (needle, replacement) in entities {
            out = out.replacingOccurrences(of: needle, with: replacement)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapse runs of whitespace so a summary can be shown on one or two lines.
    var collapsedWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
