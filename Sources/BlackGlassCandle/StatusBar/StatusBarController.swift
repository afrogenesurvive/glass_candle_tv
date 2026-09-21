import AppKit
import SwiftUI

/// A borderless window that can still become key.
///
/// This subclass is load-bearing, not decoration. A default borderless
/// `NSWindow` returns `false` from `canBecomeKey`, so it never becomes the key
/// window — and a window that is not key receives no keyboard input. The visible
/// symptom is a SwiftUI `TextField` inside the popover that renders correctly,
/// accepts focus, and then ignores every keystroke.
///
/// DS-mon carries the same workaround for the same reason.
private final class PopoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {

    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var statusView: StatusBarView?
    private var popoverWindow: PopoverWindow?
    private var settingsWindow: NSWindow?
    private var eventMonitor: Any?

    private var labelTimer: Timer?
    private var pulseTimer: Timer?
    private var pulseStart = Date()
    private var lastAppliedWidth: CGFloat = 0

    private var client: FreshRSSClient?
    private var prefs: PrefsStore?

    private let popoverSize = NSSize(width: 380, height: 520)
    private let settingsSize = NSSize(width: 520, height: 460)

    private override init() { super.init() }

    // MARK: Setup

    func setUp(client: FreshRSSClient, prefs: PrefsStore) {
        guard statusItem == nil else { return }
        self.client = client
        self.prefs = prefs

        // variableLength because the width depends on the count: 3 unread and
        // 128 unread need very different room, and a fixed width would either
        // clip or waste space permanently.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            let view = StatusBarView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            view.target = self
            view.action = #selector(togglePopover)
            view.rightAction = #selector(showContextMenu)
            button.addSubview(view)
            statusView = view
        }

        buildPopoverWindow()
        refreshLabel(force: true)
        startLabelTimer()

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: PrefsStore.didChange, object: nil
        )
    }

    private func buildPopoverWindow() {
        guard let client, let prefs else { return }

        let window = PopoverWindow(
            contentRect: NSRect(origin: .zero, size: popoverSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .popUpMenu
        // isReleasedWhenClosed = false: the window is reused for the whole app
        // lifetime. Letting it release would leave a dangling reference the next
        // time the user clicks the icon.
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PopoverView(client: client, prefs: prefs)
        )
        popoverWindow = window
    }

    // MARK: Preferences

    @objc private func preferencesChanged() {
        // The label timer would pick this up within a second anyway; forcing it
        // makes toggles in the settings window feel immediate.
        refreshLabel(force: true)
    }

    // MARK: Label

    /// The timer only exists to poll the observable client. `@Observable` does
    /// not notify an NSView, and a 1s poll of in-memory state is cheaper and far
    /// simpler than plumbing observation into AppKit.
    private func startLabelTimer() {
        labelTimer?.invalidate()
        labelTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLabel() }
        }
        if let timer = labelTimer {
            // .common so the item keeps updating while a menu is tracking.
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func refreshLabel(force: Bool = false) {
        guard let client, let prefs, let view = statusView, let item = statusItem else { return }

        let level = client.flameLevel
        let levelChanged = view.flameLevel != level

        view.flameLevel = level
        view.showIcon = prefs.showIcon
        view.showFlame = prefs.showFlameIndicator
        view.text = prefs.showIcon || prefs.menuBarTextMode != .off ? client.menuBarText : ""

        // Only resize the status item when the width actually changed. Setting it
        // every second causes visible jitter in the menu bar.
        let width = view.preferredWidth
        if force || abs(width - lastAppliedWidth) > 0.5 {
            item.length = width
            view.frame = NSRect(x: 0, y: 0, width: width, height: 22)
            lastAppliedWidth = width
        }

        if levelChanged { view.needsDisplay = true }

        // The pulse is a call to attention, so it only runs when there is
        // something to attend to. Leaving it on permanently would mean redrawing
        // the status item ten times a second forever.
        if level == .high {
            startPulseTimer()
        } else {
            stopPulseTimer()
            view.pulsePhase = 1.0
        }

        // The popover reads the client directly via @Observable, so nothing else
        // needs pushing to it here.
        _ = client
    }

    private func startPulseTimer() {
        guard pulseTimer == nil else { return }
        pulseStart = Date()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let view = self.statusView else { return }
                let elapsed = Date().timeIntervalSince(self.pulseStart)
                // ~2.4s period, easing between 45% and 100% opacity.
                let phase = 0.45 + 0.55 * (0.5 + 0.5 * sin(elapsed * 2 * .pi / 2.4))
                view.pulsePhase = CGFloat(phase)
            }
        }
        if let timer = pulseTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopPulseTimer() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    // MARK: Popover

    @objc private func togglePopover() {
        guard let window = popoverWindow else { return }
        if window.isVisible {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let window = popoverWindow,
              let button = statusItem?.button else { return }

        // Position under the status item, centred, with a small gap.
        let buttonFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        let size = window.frame.size
        var x = buttonFrame.midX - size.width / 2
        let y = buttonFrame.minY - size.height - 4

        // Keep the panel on screen when the item is near the right edge.
        if let screen = button.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }

        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Close when the user clicks anywhere else. The global monitor covers
        // other apps; windowDidResignKey covers clicks inside this app.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopover() {
        popoverWindow?.orderOut(nil)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.closePopover() }
    }

    // MARK: Context menu

    private func menuItem(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showContextMenu() {
        guard let button = statusItem?.button, let client else { return }

        let menu = NSMenu()

        let status = NSMenuItem(title: client.status.label, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(menuItem("Open FreshRSS", #selector(menuOpenWebUI)))
        menu.addItem(menuItem("Refresh Now", #selector(menuRefresh)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(showSettings), ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit black_glass_candle", #selector(menuQuit), "q"))

        // popUp returns a Bool; discarding it explicitly keeps the intent clear.
        _ = menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
    }

    @objc private func menuOpenWebUI() { client?.openWebUI() }

    @objc private func menuRefresh() {
        Task { await client?.refresh(manual: true) }
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Settings window

    @objc func showSettings() {
        guard let client, let prefs else { return }

        // Rebuild each time so the form reflects current Keychain/prefs state.
        // A cached window would show stale values after a password rotation.
        if let existing = settingsWindow {
            existing.close()
            settingsWindow = nil
        }

        let hosting = NSHostingController(
            rootView: SettingsView(client: client, prefs: prefs)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "black_glass_candle"
        window.styleMask = [.titled, .closable]
        window.setContentSize(settingsSize)
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        closePopover()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Teardown

    func shutdown() {
        labelTimer?.invalidate()
        labelTimer = nil
        stopPulseTimer()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
