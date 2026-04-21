import Foundation

// MARK: - Cycle Strategy Protocol

/// Determines when a worker should be cycled (process replaced).
/// Pluggable to support future token-based thresholds.
protocol CycleStrategy {
    func shouldCycle(tasksSinceSpawn: Int, settings: CycleSettings) -> Bool
}

/// Default v1 strategy: cycle after N completed tasks.
struct TaskCountStrategy: CycleStrategy {
    func shouldCycle(tasksSinceSpawn: Int, settings: CycleSettings) -> Bool {
        settings.cycleTasks > 0 && tasksSinceSpawn >= settings.cycleTasks
    }
}

// MARK: - Cycle Settings (read from UserDefaults at point-of-use)

struct CycleSettings {
    /// Cycle after N tasks (0 = disabled). Default 4.
    var cycleTasks: Int {
        let val = UserDefaults.standard.integer(forKey: "sonata.cycleTasks")
        return (1...50).contains(val) ? val : (val == 0 ? 0 : 4)
    }

    /// Seconds to wait for replacement to register. Default 30.
    var spawnTimeout: TimeInterval {
        let val = UserDefaults.standard.integer(forKey: "sonata.spawnTimeout")
        return (5...300).contains(val) ? TimeInterval(val) : 30
    }

    /// Seconds after SIGTERM before SIGKILL. Default 10.
    var sigtermGrace: TimeInterval {
        let val = UserDefaults.standard.integer(forKey: "sonata.sigtermGrace")
        return (1...60).contains(val) ? TimeInterval(val) : 10
    }

    /// Consecutive spawn failures before supervisor alert. Default 3.
    var cycleFailAlert: Int {
        let val = UserDefaults.standard.integer(forKey: "sonata.cycleFailAlert")
        return (1...20).contains(val) ? val : 3
    }

    /// When true, cycling is paused across all workers.
    var pauseCycling: Bool {
        UserDefaults.standard.bool(forKey: "sonata.pauseCycling")
    }

    static let shared = CycleSettings()
}
