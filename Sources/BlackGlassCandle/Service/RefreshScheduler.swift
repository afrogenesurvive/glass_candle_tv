import Foundation

/// Drives the periodic background refresh.
///
/// A `Task` loop rather than a `Timer`: `Timer` callbacks cannot `await`, so a
/// slow refresh would either block the run loop or overlap with the next tick.
/// A sleep-loop serialises naturally — the next refresh cannot start until the
/// previous one has finished, so a slow or hanging instance degrades into a
/// longer interval instead of a queue of in-flight requests.
@MainActor
final class RefreshScheduler {

    private var task: Task<Void, Never>?
    private var currentInterval: TimeInterval = 0
    private let client: FreshRSSClient
    private let prefs: PrefsStore

    init(client: FreshRSSClient, prefs: PrefsStore) {
        self.client = client
        self.prefs = prefs
    }

    var isRunning: Bool { task != nil }

    /// Start (or restart) polling. Passing the same interval is a no-op, so this
    /// is safe to call from a preferences-changed notification.
    func start(interval seconds: Int? = nil) {
        let interval = TimeInterval(max(15, seconds ?? prefs.refreshSeconds))

        // Already running at this interval — leave it alone. Restarting would
        // reset the countdown on every unrelated settings change.
        if task != nil, currentInterval == interval { return }

        stop()
        currentInterval = interval

        task = Task { [weak self] in
            guard let self else { return }

            // Refresh immediately, then settle into the interval. Waiting a full
            // interval first would leave the menu bar blank for five minutes
            // after launch.
            await self.client.refresh()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return   // cancelled during sleep
                }
                if Task.isCancelled { return }
                await self.client.refresh()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        currentInterval = 0
    }

    /// Run a refresh now without disturbing the interval timer.
    func refreshNow(manual: Bool = true) async {
        await client.refresh(manual: manual)
    }
}
