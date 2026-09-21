import Foundation
import Observation

/// User settings, backed by `UserDefaults`.
///
/// Credentials are deliberately NOT here — only the non-secret connection
/// parameters. The API password lives in the Keychain (`KeychainStore`).
///
/// The defaults written by `scripts/seed_menubar_config.sh` use exactly these
/// key names against the same bundle identifier, so the script and the app
/// agree without any shared config file.
@MainActor
@Observable
final class PrefsStore {

    /// Must match BUNDLE_ID in scripts/seed_menubar_config.sh.
    static let bundleID = "com.afrogenesurvive.black-glass-candle"

    static let shared = PrefsStore()

    private enum Key {
        static let apiBaseURL         = "apiBaseURL"
        static let apiUser            = "apiUser"
        static let refreshSeconds     = "refreshSeconds"
        static let menuBarTextMode    = "menuBarTextMode"
        static let showFlameIndicator = "showFlameIndicator"
        static let useEmbeddedWebView = "useEmbeddedWebView"
        static let showIcon           = "showIcon"
        static let launchAtLogin      = "launchAtLogin"
        static let rssBridgeURL       = "rssBridgeURL"
    }

    static let defaultBaseURL = "http://127.0.0.1:8080/api/greader.php"
    static let defaultBridgeURL = "http://127.0.0.1:3000"

    private let defaults = UserDefaults.standard

    // MARK: Connection

    var apiBaseURL: String {
        didSet { defaults.set(apiBaseURL, forKey: Key.apiBaseURL); notify() }
    }

    var apiUser: String {
        didSet { defaults.set(apiUser, forKey: Key.apiUser); notify() }
    }

    /// RSS-Bridge root, used only for the liveness dot in the popover footer.
    /// Empty disables the probe entirely.
    var rssBridgeURL: String {
        didSet { defaults.set(rssBridgeURL, forKey: Key.rssBridgeURL); notify() }
    }

    /// Clamped on read so a hand-edited plist cannot set a 1-second poll and
    /// hammer the instance. 15s is the floor; below that it is not a feed reader.
    var refreshSeconds: Int {
        didSet {
            let clamped = min(max(refreshSeconds, 15), 86_400)
            if clamped != refreshSeconds {
                refreshSeconds = clamped
                return   // didSet re-enters once with the clamped value
            }
            defaults.set(refreshSeconds, forKey: Key.refreshSeconds)
            notify()
        }
    }

    // MARK: Appearance

    var menuBarTextMode: MenuBarTextMode {
        didSet {
            defaults.set(menuBarTextMode.rawValue, forKey: Key.menuBarTextMode)
            notify()
        }
    }

    var showFlameIndicator: Bool {
        didSet { defaults.set(showFlameIndicator, forKey: Key.showFlameIndicator); notify() }
    }

    var showIcon: Bool {
        didSet { defaults.set(showIcon, forKey: Key.showIcon); notify() }
    }

    var useEmbeddedWebView: Bool {
        didSet { defaults.set(useEmbeddedWebView, forKey: Key.useEmbeddedWebView); notify() }
    }

    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    // MARK: Init

    private init() {
        // `object(forKey:)` rather than `string(forKey:)` so an unset key is
        // distinguishable from one deliberately set to an empty string.
        apiBaseURL = defaults.string(forKey: Key.apiBaseURL) ?? Self.defaultBaseURL
        apiUser = defaults.string(forKey: Key.apiUser) ?? "admin"
        rssBridgeURL = defaults.string(forKey: Key.rssBridgeURL) ?? Self.defaultBridgeURL

        let storedSeconds = defaults.object(forKey: Key.refreshSeconds) as? Int
        refreshSeconds = min(max(storedSeconds ?? 300, 15), 86_400)

        let storedMode = defaults.string(forKey: Key.menuBarTextMode)
        menuBarTextMode = storedMode.flatMap(MenuBarTextMode.init(rawValue:)) ?? .unread

        showFlameIndicator = defaults.object(forKey: Key.showFlameIndicator) as? Bool ?? true
        showIcon = defaults.object(forKey: Key.showIcon) as? Bool ?? true
        useEmbeddedWebView = defaults.object(forKey: Key.useEmbeddedWebView) as? Bool ?? false
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
    }

    // MARK: Derived

    /// The web UI root, for "Open FreshRSS".
    ///
    /// Derived from the API URL by stripping the `/api/greader.php` suffix, so
    /// there is only ever one URL for the user to get wrong.
    var webUIURL: URL? {
        var raw = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        for suffix in ["/api/greader.php", "/api/greader", "/api"] where raw.hasSuffix(suffix) {
            raw.removeLast(suffix.count)
            break
        }
        return URL(string: raw)
    }

    /// The parsed API endpoint, or nil when the stored string is unusable.
    var apiURL: URL? {
        let raw = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// The parsed bridge endpoint. nil when blank, which disables the probe.
    var rssBridgeEndpoint: URL? {
        let raw = rssBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Posted whenever a setting changes, so the status bar can redraw and the
    /// scheduler can re-read its interval.
    static let didChange = Notification.Name("black_glass_candle.prefsDidChange")

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
