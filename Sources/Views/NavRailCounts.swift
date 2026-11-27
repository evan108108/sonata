import Foundation
import GRDB

/// Tracks the badge counts shown on the left nav rail for Tasks and Plugins,
/// plus whether the Sonata Studio plugin is live (which decides whether the
/// Studio tab appears at all). Worker count comes directly from
/// `WorkerManager.shared.workers`. Studio unread count is owned by
/// `StudioUnreadCounts` (separate observable).
@MainActor
final class NavRailCounts: ObservableObject {
    @Published private(set) var activeTaskCount: Int = 0
    @Published private(set) var failedPluginCount: Int = 0
    /// True while the `sonata-studio` plugin row is in a live state (see
    /// `isLivePluginStatus`). Starts true so the common case, Studio
    /// installed and running, doesn't flicker out of the rail at launch
    /// before the first observation lands.
    @Published private(set) var studioPluginEnabled: Bool = true

    /// The plugin row that backs the Studio tab.
    nonisolated static let studioPluginName = "sonata-studio"

    private var taskCancellable: AnyDatabaseCancellable?
    private var pluginCancellable: AnyDatabaseCancellable?
    private var studioPluginCancellable: AnyDatabaseCancellable?

    /// Whether a `plugins.status` value means the plugin is usable. Anything
    /// else — `disabled`, `failed`, `installed`, or no row at all — hides the
    /// Studio tab, because StudioView talks to the plugin's routes and has
    /// nothing to show without it. PluginManager writes these values.
    nonisolated static func isLivePluginStatus(_ status: String?) -> Bool {
        switch status {
        case "enabled", "starting", "running": return true
        default: return false
        }
    }

    /// The rail items to show: everything, minus Studio while its plugin
    /// isn't live.
    nonisolated static func visibleItems(_ items: [NavRailItem], studioPluginEnabled: Bool) -> [NavRailItem] {
        studioPluginEnabled ? items : items.filter { $0.tab != .studio }
    }

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
                    SELECT status FROM plugins WHERE name = ?
                    """, arguments: [NavRailCounts.studioPluginName])
            }
            .start(
                in: dbPool,
                scheduling: .async(onQueue: .main),
                onError: { NSLog("[NavRailCounts] studio plugin: \($0)") },
                onChange: { [weak self] status in
                    let live = NavRailCounts.isLivePluginStatus(status)
                    MainActor.assumeIsolated { self?.studioPluginEnabled = live }
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
