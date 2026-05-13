import Foundation
import GRDB

/// Tracks the badge counts shown on the left nav rail for Tasks and Plugins,
/// plus the enabled state of the Sonata Studio plugin (used to gate the Studio
/// tab's visibility). Worker count comes directly from
/// `WorkerManager.shared.workers`. Studio unread count is owned by
/// `StudioUnreadCounts` (separate observable).
@MainActor
final class NavRailCounts: ObservableObject {
    @Published private(set) var activeTaskCount: Int = 0
    @Published private(set) var failedPluginCount: Int = 0
    /// True when the `sonata-studio` plugin row exists and its status is
    /// one of the live states (enabled/starting/running). Drives whether the
    /// Studio tab appears in the nav rail.
    @Published private(set) var studioPluginEnabled: Bool = false

    private var taskCancellable: AnyDatabaseCancellable?
    private var pluginCancellable: AnyDatabaseCancellable?
    private var studioPluginCancellable: AnyDatabaseCancellable?

    func start(dbPool: DatabasePool) {
        if taskCancellable == nil {
            taskCancellable = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM tasks WHERE status = 'active'
                    """) ?? 0
            }
            .start(
                in: dbPool,
                scheduling: .async(onQueue: .main),
                onError: { NSLog("[NavRailCounts] tasks: \($0)") },
                onChange: { [weak self] count in
                    MainActor.assumeIsolated { self?.activeTaskCount = count }
                }
            )
        }

        if pluginCancellable == nil {
            pluginCancellable = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM plugins WHERE status = 'failed'
                    """) ?? 0
            }
            .start(
                in: dbPool,
                scheduling: .async(onQueue: .main),
                onError: { NSLog("[NavRailCounts] plugins: \($0)") },
                onChange: { [weak self] count in
                    MainActor.assumeIsolated { self?.failedPluginCount = count }
                }
            )
        }

        if studioPluginCancellable == nil {
            studioPluginCancellable = ValueObservation.tracking { db in
                try String.fetchOne(db, sql: """
                    SELECT status FROM plugins WHERE name = 'sonata-studio'
                    """)
            }
            .start(
                in: dbPool,
                scheduling: .async(onQueue: .main),
                onError: { NSLog("[NavRailCounts] studio plugin: \($0)") },
                onChange: { [weak self] status in
                    let enabled: Bool
                    switch status {
                    case "enabled", "starting", "running": enabled = true
                    default: enabled = false
                    }
                    MainActor.assumeIsolated { self?.studioPluginEnabled = enabled }
                }
            )
        }
    }

    func stop() {
        taskCancellable?.cancel()
        pluginCancellable?.cancel()
        studioPluginCancellable?.cancel()
        taskCancellable = nil
        pluginCancellable = nil
        studioPluginCancellable = nil
    }

    deinit {
        taskCancellable?.cancel()
        pluginCancellable?.cancel()
        studioPluginCancellable?.cancel()
    }
}
