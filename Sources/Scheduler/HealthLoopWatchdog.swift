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
        let generation: Int
        let step: String
        let cycleSeconds: Int
        let stepSeconds: Int
    }

    private let lock = NSLock()
    private var generation = 0
    private var cycleStartedAt: Date?
    private var step = "idle"
    private var stepStartedAt = Date.distantPast
    private var completed = 0

    /// Start a new generation, abandoning whatever loop held the previous one.
    func newGeneration() -> Int {
        lock.withLock {
            generation += 1
            cycleStartedAt = nil
            step = "idle"
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
    /// Poll `progress` every `interval`; call `onStall` for a cycle stuck past
    /// `threshold`. Runs until cancelled. `onStall` is expected to replace the
    /// loop (new generation), so the same stall is not reported twice.
    static func run(
        progress: HealthCycleProgress,
        interval: TimeInterval,
        threshold: TimeInterval,
        onStall: @Sendable (HealthCycleProgress.Stall) async -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            if let stall = progress.stall(now: Date(), threshold: threshold) {
                await onStall(stall)
            }
        }
    }
}
