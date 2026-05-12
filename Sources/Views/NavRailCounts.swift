import Foundation
import GRDB

/// Tracks the badge counts shown on the left nav rail for Tasks and Plugins.
/// Worker count comes directly from `WorkerManager.shared.workers`. Studio
/// unread count is owned by `StudioUnreadCounts` (separate observable).
@MainActor
final class NavRailCounts: ObservableObject {
    @Published private(set) var activeTaskCount: Int = 0
    @Published private(set) var failedPluginCount: Int = 0

    private var taskCancellable: AnyDatabaseCancellable?
    private var pluginCancellable: AnyDatabaseCancellable?

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
    }

    func stop() {
        taskCancellable?.cancel()
        pluginCancellable?.cancel()
        taskCancellable = nil
        pluginCancellable = nil
    }

    deinit {
        taskCancellable?.cancel()
        pluginCancellable?.cancel()
    }
}
