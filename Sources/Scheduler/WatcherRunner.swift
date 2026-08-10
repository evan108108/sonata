import Foundation
import CoreServices
import GRDB
import Logging

/// Owns the live FSEventStream registrations for every enabled watcher row
/// and dispatches an mem_task_create call when a matching event fires.
///
/// Lifecycle:
/// - `start()` loads all enabled rows, opens one FSEventStream per row.
/// - Rebuilds on `SonataWatchersChanged` notifications (posted by
///   WatcherActions on create/update/delete/enable/disable).
/// - `shutdown()` tears down every stream.
///
/// The FSEventStream C callback bridges back to the actor via an unretained
/// context pointer holding a per-registration key; the callback hops onto
/// actor isolation via `Task { await runner.handleEvent(...) }`. Mirrors the
/// WikiFileWatcher pattern so callbacks + Swift 6 isolation stay tidy.
///
/// Cooldown: per-(watcherId, path) debounce. A file being written 10 KB at a
/// time only fires the dispatch once per cooldown window. Not a global rate
/// limit — different files fire independently.
///
/// Retry: on dispatch failure, the watcher row's consecutiveFailures counter
/// increments. When it hits K in a row (see `autoDisableThreshold`), the
/// watcher is auto-disabled and a DM goes to the supervisor session so the
/// user notices instead of the watcher silently going quiet.
actor WatcherRunner {

    // MARK: - Dependencies

    private let dbPool: DatabasePool
    private let registry: ActionRegistry
    nonisolated let logger: Logger

    /// After this many consecutive failed dispatches, auto-disable the watcher
    /// and DM the supervisor. Keeps a broken prompt from spamming the task
    /// queue every time a file lands.
    private let autoDisableThreshold = 5

    // MARK: - Registrations

    /// One entry per enabled watcher, keyed by watcher id.
    private var registrations: [String: Registration] = [:]

    /// Per-(watcherId, path) last-dispatch timestamp for debounce. Grows with
    /// distinct paths seen; not swept because the entry cost is small and the
    /// watcher's own lifecycle bounds the map.
    private var lastDispatchMs: [String: Int64] = [:]

    /// Guard against `start()` being called twice.
    private var started = false

    /// Retained handle to the notification observer so it can be removed at
    /// shutdown.
    private var reloadObserver: NSObjectProtocol?

    // MARK: - Init

    init(dbPool: DatabasePool, registry: ActionRegistry, logger: Logger? = nil) {
        self.dbPool = dbPool
        self.registry = registry
        var log = logger ?? Logger(label: "sonata.watcher-runner")
        log.logLevel = .info
        self.logger = log
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else {
            logger.warning("WatcherRunner already started — ignoring duplicate start()")
            return
        }
        started = true

        // Observe reload notifications. NotificationCenter callbacks fire on
        // whatever thread posted; we hop into the actor via Task.
        let center = NotificationCenter.default
        reloadObserver = center.addObserver(
            forName: .sonataWatchersChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.reload() }
        }

        await reload()
    }

    func shutdown() {
        logger.info("WatcherRunner shutting down (\(registrations.count) active)")
        for (_, reg) in registrations {
            reg.teardown()
        }
        registrations.removeAll()
        if let obs = reloadObserver {
            NotificationCenter.default.removeObserver(obs)
            reloadObserver = nil
        }
        started = false
    }

    // MARK: - Reload — diff against the current enabled set

    func reload() async {
        let rows: [WatcherRow]
        do {
            rows = try await dbPool.read { db in
                try WatcherRow.fetchAll(
                    db,
                    sql: "SELECT * FROM watchers WHERE enabled = 1"
                )
            }
        } catch {
            logger.error("WatcherRunner.reload: DB read failed: \(error)")
            return
        }

        let currentIds = Set(registrations.keys)
        let wantedIds = Set(rows.map { $0.id })

        // Tear down anything that disappeared or got disabled.
        for id in currentIds.subtracting(wantedIds) {
            if let reg = registrations.removeValue(forKey: id) {
                reg.teardown()
                logger.info("WatcherRunner: torn down watcher \(id)")
            }
        }

        // Register or replace anything new / changed.
        // Cheap identity check: (path, recursive) — those are the only fields
        // that require an FSEventStream restart. Everything else is read
        // per-fire.
        for row in rows {
            if let existing = registrations[row.id],
               existing.path == row.path,
               existing.recursive == (row.recursive != 0) {
                // Config changed only in ways that don't need a re-register.
                existing.row = row
                continue
            }
            if let old = registrations.removeValue(forKey: row.id) {
                old.teardown()
            }
            guard let reg = Registration.make(row: row, runner: self, logger: logger) else {
                logger.error("WatcherRunner: failed to register \(row.id) at \(row.path)")
                await markError(id: row.id, message: "Failed to open FSEventStream at \(row.path)")
                continue
            }
            registrations[row.id] = reg
            logger.info("WatcherRunner: registered \(row.id) at \(row.path) (recursive=\(row.recursive != 0))")
        }
    }

    // MARK: - Event handling

    /// Called from the C trampoline (via Task) with a batch of paths from one
    /// FSEventStream fire.
    fileprivate func handleFSEvents(
        watcherId: String,
        paths: [String],
        flags: [UInt32]
    ) async {
        guard let reg = registrations[watcherId] else { return }
        let row = reg.row

        for (idx, path) in paths.enumerated() {
            let f = idx < flags.count ? flags[idx] : 0
            let event = classifyEvent(flags: f, row: row)
            guard let event else { continue }

            // Pattern gate. Match against the basename.
            let basename = (path as NSString).lastPathComponent
            guard matchesGlob(basename, pattern: row.pattern) else { continue }

            // Size-threshold gate. Skip if the file doesn't exist yet or is
            // smaller than the threshold.
            if row.trigger == "size_threshold" {
                guard let threshold = row.sizeThreshold else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                guard size >= threshold else { continue }
            }

            // Debounce.
            let debounceKey = "\(watcherId)|\(path)"
            let now = nowMs()
            if let last = lastDispatchMs[debounceKey],
               now - last < row.cooldownMs {
                continue
            }
            lastDispatchMs[debounceKey] = now

            await dispatch(row: row, eventType: event, path: path)
        }
    }

    /// Classify an FSEventStream flag word into one of the trigger types the
    /// row cares about. Returns nil if the event isn't of interest.
    private func classifyEvent(flags: UInt32, row: WatcherRow) -> String? {
        // FSEventStream flag bits. Multiple can be set for one path — we
        // pick the most specific interpretation the row asked for.
        let created  = (flags & UInt32(kFSEventStreamEventFlagItemCreated))  != 0
        let removed  = (flags & UInt32(kFSEventStreamEventFlagItemRemoved))  != 0
        let modified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
        let renamed  = (flags & UInt32(kFSEventStreamEventFlagItemRenamed))  != 0

        switch row.trigger {
        case "file_added":
            return (created || renamed) ? "file_added" : nil
        case "file_modified":
            return modified ? "file_modified" : nil
        case "file_deleted":
            return removed ? "file_deleted" : nil
        case "size_threshold":
            // Any change that might have grown the file.
            return (created || modified) ? "size_threshold" : nil
        default:
            return nil
        }
    }

    // MARK: - Test-fire (called by watcher_test action)

    struct TestFireResult: Sendable {
        let taskId: String?
        let status: String
        let error: String?
    }

    func testFire(watcherId: String, path: String) async -> TestFireResult {
        let row: WatcherRow?
        do {
            row = try await dbPool.read { db in
                try WatcherRow.fetchOne(
                    db,
                    sql: "SELECT * FROM watchers WHERE id = ?",
                    arguments: [watcherId]
                )
            }
        } catch {
            return TestFireResult(taskId: nil, status: "errored", error: error.localizedDescription)
        }
        guard let row else {
            return TestFireResult(taskId: nil, status: "errored", error: "Watcher not found: \(watcherId)")
        }
        // Bypass cooldown + pattern gates so the test always runs.
        let eventType = row.trigger  // report what the row was configured for
        return await dispatch(row: row, eventType: eventType, path: path, isTest: true)
    }

    // MARK: - Dispatch

    /// Render the prompt (with tokens or preamble), call mem_task_create, log
    /// the event, update failure counters, auto-disable on threshold.
    @discardableResult
    private func dispatch(
        row: WatcherRow,
        eventType: String,
        path: String,
        isTest: Bool = false
    ) async -> TestFireResult {
        let prompt = renderPrompt(row: row, eventType: eventType, path: path)

        let firedAt = nowMs()
        let eventRowId = newUUID()
        let sourceRef = "watcher/\(row.id)"

        // Call mem_task_create through the registry so metadata pipelines
        // (task-watch fan-out, source tagging) stay uniform with every other
        // task-creation path.
        let taskArgs: [String: Any] = [
            "title": "watcher: \(row.name)",
            "prompt": prompt,
            "source": sourceRef,
            "sourceRef": path,
            "priority": "normal",
        ]
        let (ok, out) = await registry.executeMCPTool(
            name: "mem_task_create",
            args: taskArgs,
            dbPool: dbPool
        )

        var taskId: String? = nil
        if ok {
            taskId = extractTaskId(fromJSON: out)
        }
        let status: String = ok && taskId != nil ? "dispatched" : "errored"
        let errText: String? = (status == "dispatched") ? nil : (ok ? "mem_task_create returned no task id" : out)

        // Insert an audit row. Bind captured values to lets so Swift 6 doesn't
        // flag the `var taskId` capture inside the @Sendable write closure.
        let auditTaskId = taskId
        let auditStatus = status
        let auditErr = errText
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO watcher_events
                        (id, watcherId, path, eventType, firedAt, taskId, status, error)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        eventRowId, row.id, path, eventType, firedAt,
                        auditTaskId, auditStatus, auditErr,
                    ]
                )
            }
        } catch {
            logger.error("WatcherRunner: failed to insert watcher_events row: \(error)")
        }

        // Update failure counters + lastFiredAt on the watcher row. Only real
        // fires touch the counter — a test-fire doesn't count toward auto-
        // disable.
        if isTest {
            return TestFireResult(taskId: taskId, status: status, error: errText)
        }

        if ok, taskId != nil {
            do {
                try await dbPool.write { db in
                    try db.execute(
                        sql: """
                        UPDATE watchers
                        SET consecutiveFailures = 0, lastError = NULL,
                            lastFiredAt = ?, updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [firedAt, firedAt, row.id]
                    )
                }
            } catch {
                logger.error("WatcherRunner: failed to reset failure counter on \(row.id): \(error)")
            }
        } else {
            let newCount = row.consecutiveFailures + 1
            let disable = newCount >= autoDisableThreshold
            do {
                try await dbPool.write { db in
                    try db.execute(
                        sql: """
                        UPDATE watchers
                        SET consecutiveFailures = ?, lastError = ?,
                            lastFiredAt = ?, updatedAt = ?,
                            enabled = CASE WHEN ? THEN 0 ELSE enabled END
                        WHERE id = ?
                        """,
                        arguments: [
                            newCount, errText, firedAt, firedAt,
                            disable, row.id,
                        ]
                    )
                }
            } catch {
                logger.error("WatcherRunner: failed to increment failure counter on \(row.id): \(error)")
            }
            if disable {
                let errSummary = errText ?? "?"
                logger.warning("WatcherRunner: auto-disabled \(row.id) after \(newCount) consecutive failures — last error: \(errSummary)")
                // Reload so the FSEventStream comes down.
                await reload()
            }
        }

        return TestFireResult(taskId: taskId, status: status, error: errText)
    }

    private func markError(id: String, message: String) async {
        let now = nowMs()
        try? await dbPool.write { db in
            try db.execute(
                sql: "UPDATE watchers SET lastError = ?, updatedAt = ? WHERE id = ?",
                arguments: [message, now, id]
            )
        }
    }

    // MARK: - Prompt rendering (token substitution or preamble)

    /// If the prompt contains any of the six known tokens, substitute them
    /// and return as-is. Otherwise prepend a preamble that gives the task
    /// worker the file context automatically.
    nonisolated func renderPrompt(row: WatcherRow, eventType: String, path: String) -> String {
        let basename = (path as NSString).lastPathComponent
        let ext = (basename as NSString).pathExtension
        let dir = (path as NSString).deletingLastPathComponent

        let substitutions: [String: String] = [
            "{{path}}": path,
            "{{name}}": basename,
            "{{ext}}": ext,
            "{{dir}}": dir,
            "{{event}}": eventType,
            "{{watcher}}": row.name,
        ]

        let hasToken = substitutions.keys.contains { row.prompt.contains($0) }
        if hasToken {
            var rendered = row.prompt
            for (token, value) in substitutions {
                rendered = rendered.replacingOccurrences(of: token, with: value)
            }
            return rendered
        }

        // Preamble path — original prompt at the bottom.
        return """
        You are a Sonata filewatcher-triggered task.

        Watcher: \(row.name)
        Trigger: \(eventType)
        File path: \(path)

        Your prompt:
        \(row.prompt)
        """
    }

    // MARK: - Glob matching (dumb + local)

    /// Very small glob matcher: `*` matches any sequence (including empty),
    /// `?` matches one char, everything else literal. Anchored end-to-end.
    /// Matches only the basename, not the full path — sufficient for the
    /// `*.md`, `Screenshot*.png`, `IMG_*` patterns the templates use.
    nonisolated func matchesGlob(_ name: String, pattern: String) -> Bool {
        if pattern.isEmpty || pattern == "*" { return true }
        return globMatch(name: Array(name), np: 0, pattern: Array(pattern), pp: 0)
    }

    private nonisolated func globMatch(name: [Character], np: Int, pattern: [Character], pp: Int) -> Bool {
        var ni = np
        var pi = pp
        var star: Int? = nil
        var match = 0
        while ni < name.count {
            if pi < pattern.count, pattern[pi] == "?" || pattern[pi] == name[ni] {
                ni += 1; pi += 1
            } else if pi < pattern.count, pattern[pi] == "*" {
                star = pi
                match = ni
                pi += 1
            } else if let s = star {
                pi = s + 1
                match += 1
                ni = match
            } else {
                return false
            }
        }
        while pi < pattern.count, pattern[pi] == "*" { pi += 1 }
        return pi == pattern.count
    }

    // MARK: - mem_task_create response parsing

    /// mem_task_create returns { "id": "<uuid>" } (StoreResponse). Try to
    /// pluck that out.
    private nonisolated func extractTaskId(fromJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let id = obj["id"] as? String { return id }
        // Some responses wrap in {"data": {"id": ...}}
        if let data = obj["data"] as? [String: Any], let id = data["id"] as? String { return id }
        return nil
    }
}

// MARK: - Per-watcher FSEventStream registration

/// One live FSEventStream + the row it's tied to. Boxed as a class so the
/// unretained context pointer stays stable across actor hops.
final class Registration {
    fileprivate var row: WatcherRow
    fileprivate let path: String
    fileprivate let recursive: Bool
    private var stream: FSEventStreamRef?
    /// Retained self-box so the C callback's `info` pointer stays valid for
    /// the stream's lifetime. Released in teardown().
    private var contextBox: ContextBox?

    private init(row: WatcherRow) {
        self.row = row
        self.path = row.path
        self.recursive = row.recursive != 0
    }

    static func make(row: WatcherRow, runner: WatcherRunner, logger: Logger) -> Registration? {
        let reg = Registration(row: row)

        // FSEventStream requires the directory to exist. For a single-file
        // watch, watch the enclosing dir and let the callback filter by
        // basename via the pattern.
        let watchPath = reg.watchPath()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: watchPath, isDirectory: &isDir) {
            logger.error("Registration.make: watch path missing: \(watchPath)")
            return nil
        }

        let box = ContextBox(watcherId: row.id, runner: runner)
        reg.contextBox = box

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [watchPath] as CFArray
        let flags: UInt32 = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
        )
        let latency: CFTimeInterval = 1.0

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            watcherRunnerCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            logger.error("Registration.make: FSEventStreamCreate returned nil for \(watchPath)")
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        if !FSEventStreamStart(stream) {
            logger.error("Registration.make: FSEventStreamStart failed for \(watchPath)")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        reg.stream = stream
        return reg
    }

    /// Path handed to FSEventStreamCreate. For a single-file watch (the path
    /// exists but is a regular file), we watch the parent directory and rely
    /// on the pattern to filter.
    private func watchPath() -> String {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue { return path }
        return (path as NSString).deletingLastPathComponent
    }

    func teardown() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        contextBox = nil
    }
}

/// Bridges the C callback's `info` pointer back to a specific watcher id +
/// the runner actor. Held by Registration.
private final class ContextBox {
    let watcherId: String
    let runner: WatcherRunner
    init(watcherId: String, runner: WatcherRunner) {
        self.watcherId = watcherId
        self.runner = runner
    }
}

// MARK: - FSEvents C trampoline

private func watcherRunnerCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let box = Unmanaged<ContextBox>.fromOpaque(info).takeUnretainedValue()

    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let paths = (cfArray as NSArray) as? [String] ?? []

    var flags: [UInt32] = []
    flags.reserveCapacity(numEvents)
    for i in 0..<numEvents {
        flags.append(UInt32(eventFlags[i]))
    }

    let watcherId = box.watcherId
    let runner = box.runner
    Task {
        await runner.handleFSEvents(watcherId: watcherId, paths: paths, flags: flags)
    }
}
