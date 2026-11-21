import Foundation

/// Where HealthMonitor's loop is right now, readable from outside the actor.
///
/// Why it exists (2026-11-17): after the 13:27Z local relaunch, the monitor
/// loop's first cycle suspended on an await that never resumed and completed
/// zero cycles for ~40 min. Nothing noticed: every per-cycle sweep (stranded
/// event reclaim, the timeout reaper, dispatchStall, supervisor check pushes)
/// was silently off, and the same binary relaunched at 14:08Z cycled fine. The
/// loop marks each step here so a watchdog running OUTSIDE the loop can see a
/// cycle that has been in progress too long and name the step it is stuck in.
///
/// Lock-protected rather than actor-isolated on purpose: the watchdog must be
/// able to read it even if whatever wedged the loop also wedges an actor.
///
/// Generations: a stalled loop is abandoned, not killed (a suspended await
/// can't be forced to return). If it ever wakes, its marks carry the old
/// generation and are ignored, so it can't overwrite the replacement loop's
/// progress.
final class HealthCycleProgress: @unchecked Sendable {
    struct Stall: Equatable, Sendable {
        enum Kind: String, Sendable {
            /// The cycle itself has not finished: the loop is suspended in `step`.
            case cycleStuck
            /// Cycles still finish, but `step` has found the main thread
            /// unresponsive for longer than the threshold (its MainActor hop is
            /// bounded, so it reports instead of wedging the cycle).
            case mainThreadUnresponsive
        }
        let generation: Int
        let step: String
        let cycleSeconds: Int
        let stepSeconds: Int
        var kind: Kind = .cycleStuck
    }

    private let lock = NSLock()
    private var generation = 0
    private var cycleStartedAt: Date?
    private var step = "idle"
    private var stepStartedAt = Date.distantPast
    private var completed = 0
    /// First time, in the current unbroken stretch, that a bounded MainActor
    /// hop got no answer; nil once the main thread answers again.
    private var unresponsiveSince: Date?
    private var unresponsiveStep = ""
    /// The watchdog reports one unresponsive stretch once, not every tick.
    private var unresponsiveReported = false
    /// Set while a stall episode is open (alerted, not yet recovered): the
    /// completed-cycle count when it was last seen. Recovery needs a cycle
    /// finished after that, with the main thread answering.
    private var episodeCompletedMark: Int?

    /// Start a new generation, abandoning whatever loop held the previous one.
    func newGeneration() -> Int {
        lock.withLock {
            generation += 1
            cycleStartedAt = nil
            step = "idle"
            unresponsiveSince = nil
            unresponsiveReported = false
            return generation
        }
    }

    func begin(_ gen: Int, at now: Date = Date()) {
        lock.withLock {
            guard gen == generation else { return }
            cycleStartedAt = now
            step = "cycle-start"
            stepStartedAt = now
        }
    }

    func mark(_ gen: Int, _ name: String, at now: Date = Date()) {
        lock.withLock {
            guard gen == generation, cycleStartedAt != nil else { return }
            step = name
            stepStartedAt = now
        }
    }

    func end(_ gen: Int) {
        lock.withLock {
            guard gen == generation else { return }
            cycleStartedAt = nil
            step = "idle"
            completed += 1
        }
    }

    var currentGeneration: Int { lock.withLock { generation } }

    /// A bounded MainActor hop in `step` timed out. Starts (or continues) the
    /// unresponsive stretch the watchdog reports past its threshold.
    func noteMainThreadUnresponsive(_ gen: Int, step name: String, at now: Date = Date()) {
        lock.withLock {
            guard gen == generation else { return }
            if unresponsiveSince == nil {
                unresponsiveSince = now
                unresponsiveReported = false
            }
            unresponsiveStep = name
        }
    }

    /// A bounded MainActor hop answered: the unresponsive stretch is over.
    func noteMainThreadResponsive(_ gen: Int) {
        lock.withLock {
            guard gen == generation else { return }
            unresponsiveSince = nil
            unresponsiveReported = false
        }
    }

    var mainThreadUnresponsiveSince: Date? { lock.withLock { unresponsiveSince } }

    /// Non-nil once per unresponsive stretch, when it has lasted past
    /// `threshold`. Marks the stretch reported, so the next tick returns nil.
    func takeMainThreadStall(now: Date, threshold: TimeInterval) -> Stall? {
        lock.withLock {
            guard let since = unresponsiveSince, !unresponsiveReported,
                  now.timeIntervalSince(since) > threshold else { return nil }
            unresponsiveReported = true
            let secs = Int(now.timeIntervalSince(since))
            return Stall(generation: generation, step: unresponsiveStep,
                         cycleSeconds: secs, stepSeconds: secs, kind: .mainThreadUnresponsive)
        }
    }

    /// Record that a stall episode is open as of now (first alert or a repeat).
    func openStallEpisode() {
        lock.withLock { episodeCompletedMark = completed }
    }

    /// Mark an episode restored from disk at launch: any finished cycle in this
    /// process counts as recovery.
    func openRestoredStallEpisode() {
        lock.withLock { episodeCompletedMark = -1 }
    }

    func closeStallEpisode() {
        lock.withLock { episodeCompletedMark = nil }
    }

    var stallEpisodeOpen: Bool { lock.withLock { episodeCompletedMark != nil } }

    /// True when an open episode can be called recovered: a cycle finished
    /// after it was last seen, no cycle is stuck past `threshold`, and the
    /// main thread is answering.
    func stallEpisodeRecovered(now: Date, threshold: TimeInterval) -> Bool {
        lock.withLock {
            guard let mark = episodeCompletedMark, completed > mark, unresponsiveSince == nil else { return false }
            if let started = cycleStartedAt, now.timeIntervalSince(started) > threshold { return false }
            return true
        }
    }

    /// Cycles the current generation has finished.
    var completedCycles: Int { lock.withLock { completed } }

    /// Non-nil when the current generation's cycle has been running longer
    /// than `threshold`. The sleep between cycles never counts: `end` clears
    /// the cycle start before the loop sleeps.
    func stall(now: Date, threshold: TimeInterval) -> Stall? {
        lock.withLock {
            guard let started = cycleStartedAt, now.timeIntervalSince(started) > threshold else { return nil }
            return Stall(
                generation: generation,
                step: step,
                cycleSeconds: Int(now.timeIntervalSince(started)),
                stepSeconds: Int(now.timeIntervalSince(stepStartedAt))
            )
        }
    }
}

enum HealthLoopWatchdog {
    /// Poll `progress` every `interval`. Calls `onStall` for a cycle stuck past
    /// `threshold` (expected to replace the loop under a new generation, so the
    /// same stall is not reported twice) or for a main-thread-unresponsive
    /// stretch past `threshold` (reported once per stretch). Calls
    /// `onRecovered` once an open stall episode has recovered. Runs until
    /// cancelled. Reads `progress` only; it awaits the monitor only to report.
    static func run(
        progress: HealthCycleProgress,
        interval: TimeInterval,
        threshold: TimeInterval,
        onStall: @Sendable (HealthCycleProgress.Stall) async -> Void,
        onRecovered: @Sendable () async -> Void = {}
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            let now = Date()
            if let stall = progress.stall(now: now, threshold: threshold) {
                await onStall(stall)
            } else if let stall = progress.takeMainThreadStall(now: now, threshold: threshold) {
                await onStall(stall)
            } else if progress.stallEpisodeRecovered(now: now, threshold: threshold) {
                await onRecovered()
            }
        }
    }
}

/// Await `operation` for at most `seconds`. Returns nil on timeout.
///
/// The operation runs in an unstructured task, so a timeout really returns:
/// a task group would wait for a child stuck in `MainActor.run` behind a
/// blocked main thread, which is the wedge this exists to escape. On timeout
/// the operation is left running; it completes whenever its executor frees,
/// so use this only for reads and for actions that are still right to apply late.
enum BoundedAwait {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    static func value<T: Sendable>(
        within seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = Once()
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { cont.resume(returning: nil) }
            }
            Task {
                let v = await operation()
                if once.claim() {
                    timer.cancel()
                    cont.resume(returning: v)
                }
            }
        }
    }
}
