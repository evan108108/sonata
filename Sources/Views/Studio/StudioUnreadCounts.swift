import Foundation
import GRDB

/// App-level observable that tracks the total Studio unread-card count
/// across all rooms. Owned by `ContentView` so the nav-rail badge can
/// render without depending on the tab-scoped `StudioStore`.
@MainActor
final class StudioUnreadCounts: ObservableObject {
    @Published private(set) var studioTotal: Int = 0
    private var cancellable: AnyDatabaseCancellable?

    func start(dbPool: DatabasePool) {
        if cancellable != nil { return }
        cancellable = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: """
                SELECT IFNULL(SUM(unread), 0) FROM (
                  SELECT (
                    SELECT COUNT(*) FROM entities c
                    WHERE c.type = 'studio_card'
                      AND json_extract(c.attributes, '$.room_slug') = json_extract(r.attributes, '$.slug')
                      AND json_extract(c.attributes, '$.created_at_seconds') > IFNULL(json_extract(r.attributes, '$.last_seen_at_ms'), 0) / 1000
                  ) AS unread
                  FROM entities r
                  WHERE r.type = 'studio_room'
                )
                """) ?? 0
        }
        .start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: { NSLog("[StudioUnreadCounts] \($0)") },
            onChange: { [weak self] total in
                MainActor.assumeIsolated { self?.studioTotal = total }
            }
        )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    deinit {
        cancellable?.cancel()
    }
}
