import SwiftUI
import AppKit

/// Menu bar only: no Dock icon, no main window.
///
/// `Settings { }` is present because a SwiftUI `App` needs at least one `Scene`,
/// but it is never shown — the real settings window is built in AppKit by
/// `StatusBarController` so that it can be a normal titled window rather than a
/// Settings scene tied to the app menu.
@main
struct BlackGlassCandleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let prefs = PrefsStore.shared
    private let client = FreshRSSClient()
    private var scheduler: RefreshScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside LSUIElement in Info.plist. Setting it here
        // means the app also behaves correctly when run straight from
        // `.build/release/` during development, where there is no bundle.
        NSApp.setActivationPolicy(.accessory)

        StatusBarController.shared.setUp(client: client, prefs: prefs)

        let scheduler = RefreshScheduler(client: client, prefs: prefs)
        self.scheduler = scheduler

        // Settings changes need to reach the client (new URL/user) and the
        // scheduler (new interval), so both are re-armed on every change.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: PrefsStore.didChange,
            object: nil
        )

        Task { @MainActor in
            await client.reconfigure()
            scheduler.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduler?.stop()
        StatusBarController.shared.shutdown()
    }

    @objc private func preferencesChanged() {
        Task { @MainActor in
            await client.reconfigure()
            // start() is a no-op when the interval is unchanged, so this does
            // not reset the countdown on unrelated toggles.
            scheduler?.start()
            // An empty password means the user just cleared it; surface that
            // immediately rather than waiting for the next poll to fail.
            if !client.isConfigured {
                await client.refresh()
            }
        }
    }
}
