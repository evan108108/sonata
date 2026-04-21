import Foundation
import CoreServices
import GRDB
import Logging

/// Watches `~/.sonata/wiki/` and `~/.sonata/private/` for file changes
/// using FSEvents and keeps the `wikiPages` table in sync with disk.
///
/// - Wiki changes: mark existing pages dirty, register new pages, or soft-archive deleted pages.
/// - Private changes: post a `SonataPrivateFilesChanged` notification so the Files tab can refresh.
///
/// The FSEvents C callback is bridged back to the actor via an unretained
/// context pointer, and each callback hops onto actor isolation through a `Task`.
actor WikiFileWatcher {

    // MARK: - State

    private let dbPool: DatabasePool
    private let search: (any SearchService)?
    nonisolated let logger: Logger
    nonisolated let wikiDir: String
    nonisolated let privateDir: String
    private var stream: FSEventStreamRef?
    private var isRunning = false

    // MARK: - Init

    init(dbPool: DatabasePool, search: (any SearchService)? = nil, logger: Logger? = nil) {
        self.dbPool = dbPool
        self.search = search
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.wikiDir = "\(home)/.sonata/wiki"
        self.privateDir = "\(home)/.sonata/private"
        var log = logger ?? Logger(label: "sonata.wiki-file-watcher")
        log.logLevel = .info
        self.logger = log
    }

    // MARK: - Lifecycle

    /// Create and start the FSEventStream.
    func start() {
        guard !isRunning else {
            logger.warning("WikiFileWatcher already running — ignoring duplicate start()")
            return
        }

        // Ensure directories exist — FSEvents needs valid paths.
        let fm = FileManager.default
        try? fm.createDirectory(atPath: wikiDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: privateDir, withIntermediateDirectories: true)

        let pathsToWatch = [wikiDir, privateDir] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: UInt32 = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
        )
        let latency: CFTimeInterval = 2.0

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            wikiFileWatcherCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            logger.error("WikiFileWatcher: failed to create FSEventStream")
            return
        }

        FSEventStreamScheduleWithRunLoop(
            newStream,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        if !FSEventStreamStart(newStream) {
            logger.error("WikiFileWatcher: failed to start FSEventStream")
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            return
        }

        stream = newStream
        isRunning = true
        logger.info("WikiFileWatcher started (watching \(wikiDir), \(privateDir))")
    }

    /// Stop and invalidate the FSEventStream.
    func shutdown() {
        logger.info("WikiFileWatcher shutting down")
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        isRunning = false
    }

    // MARK: - Event Entry Point (called from C callback trampoline)

    fileprivate func handleEvents(paths: [String], flags: [UInt32]) async {
        for (idx, path) in paths.enumerated() {
            let f = idx < flags.count ? flags[idx] : 0

            if isUnderWikiDir(path) {
                guard path.hasSuffix(".md") else { continue }
                await processWikiEvent(path: path, flags: f)
            } else if isUnderPrivateDir(path) {
                guard path.hasSuffix(".md") || path.hasSuffix(".txt") else { continue }
                await processPrivateEvent(path: path)
                postPrivateFilesChangedNotification()
            }
        }
    }

    // MARK: - Wiki Handling

    private func processWikiEvent(path: String, flags: UInt32) async {
        guard let slug = slugFromWikiPath(path), !slug.isEmpty else { return }

        let exists = FileManager.default.fileExists(atPath: path)

        if !exists {
            await archivePage(slug: slug)
            if let search = search {
                await search.removeWikiPage(slug: slug)
            }
            return
        }

        let existingId: String?
        do {
            existingId = try await dbPool.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT id FROM wikiPages WHERE slug = ?",
                    arguments: [slug]
                )
            }
        } catch {
            logger.error("WikiFileWatcher: failed querying slug=\(slug): \(error)")
            return
        }

        if existingId != nil {
            await markDirty(slug: slug)
        } else {
            await registerNewPage(path: path, slug: slug)
        }

        // Update MeiliSearch index
        if let search = search {
            let title = readFirstLineTitle(path: path) ?? slug
            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let components = slug.split(separator: "/").map(String.init)
            let namespace = components.first
            await search.indexWikiPage(slug: slug, title: title, content: content, namespace: namespace, filePath: path)
        }
    }

    private func markDirty(slug: String) async {
        let now = nowMs()
        do {
            let changes = try await dbPool.write { db -> Int in
                try db.execute(
                    sql: """
                    UPDATE wikiPages
                    SET dirty = 1, updatedAt = ?
                    WHERE slug = ? AND dirty = 0
                    """,
                    arguments: [now, slug]
                )
                return db.changesCount
            }
            if changes > 0 {
                logger.info("WikiFileWatcher: marked \(slug) dirty")
            }
        } catch {
            logger.error("WikiFileWatcher: failed to mark \(slug) dirty: \(error)")
        }
    }

    private func archivePage(slug: String) async {
        let now = nowMs()
        do {
            let changes = try await dbPool.write { db -> Int in
                try db.execute(
                    sql: """
                    UPDATE wikiPages
                    SET pageType = 'archived', dirty = 0, updatedAt = ?
                    WHERE slug = ?
                    """,
                    arguments: [now, slug]
                )
                return db.changesCount
            }
            if changes > 0 {
                logger.info("WikiFileWatcher: archived \(slug)")
            }
        } catch {
            logger.error("WikiFileWatcher: failed to archive \(slug): \(error)")
        }
    }

    private func registerNewPage(path: String, slug: String) async {
        let title = readFirstLineTitle(path: path) ?? slug
        let components = slug.split(separator: "/").map(String.init)
        let namespace = components.first
        let topic = components.last
        let parentSlug: String? = components.count > 1
            ? components.dropLast().joined(separator: "/")
            : nil
        let pageType = components.count > 1 ? "topic" : "category"
        let now = nowMs()
        let newId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO wikiPages
                        (id, slug, title, namespace, pageType, parentSlug, topic,
                         lastCompiled, memoryCount, dirty, filePath, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 1, ?, ?, ?)
                    """,
                    arguments: [newId, slug, title, namespace, pageType, parentSlug, topic, path, now, now]
                )
            }
            logger.info("WikiFileWatcher: registered new page \(slug)")
        } catch {
            logger.error("WikiFileWatcher: failed to register new page \(slug): \(error)")
        }
    }

    // MARK: - Private Files

    private func processPrivateEvent(path: String) async {
        guard let search = search else { return }
        let prefix = privateDir + "/"
        guard path.hasPrefix(prefix) else { return }
        let relativePath = String(path.dropFirst(prefix.count))
        guard !relativePath.isEmpty else { return }

        if !FileManager.default.fileExists(atPath: path) {
            await search.removePrivateFile(filename: relativePath)
            return
        }

        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let title = readFirstLineTitle(path: path)
            ?? ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        await search.indexPrivateFile(filename: relativePath, title: title, content: content, filePath: path)
    }

    private nonisolated func postPrivateFilesChangedNotification() {
        NotificationCenter.default.post(
            name: Notification.Name("SonataPrivateFilesChanged"),
            object: nil
        )
    }

    // MARK: - Helpers

    private nonisolated func isUnderWikiDir(_ path: String) -> Bool {
        path.hasPrefix(wikiDir + "/")
    }

    private nonisolated func isUnderPrivateDir(_ path: String) -> Bool {
        path.hasPrefix(privateDir + "/")
    }

    private nonisolated func slugFromWikiPath(_ path: String) -> String? {
        let prefix = wikiDir + "/"
        guard path.hasPrefix(prefix), path.hasSuffix(".md") else { return nil }
        let relPath = String(path.dropFirst(prefix.count))
        let withoutExt = String(relPath.dropLast(3))
        return withoutExt.isEmpty ? nil : withoutExt
    }

    private nonisolated func readFirstLineTitle(path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let firstLine = content.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? ""
        var title = firstLine.trimmingCharacters(in: .whitespaces)
        if title.hasPrefix("# ") {
            title = String(title.dropFirst(2))
        } else if title.hasPrefix("#") {
            title = String(title.dropFirst(1))
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}

// MARK: - FSEvents C Callback

/// C trampoline for FSEvents. Bridges the `info` context pointer back to
/// a `WikiFileWatcher` actor reference and hops onto actor isolation via `Task`.
private func wikiFileWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<WikiFileWatcher>.fromOpaque(info).takeUnretainedValue()

    // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArrayRef of CFStrings.
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let paths = (cfArray as NSArray) as? [String] ?? []

    var flags: [UInt32] = []
    flags.reserveCapacity(numEvents)
    for i in 0..<numEvents {
        flags.append(UInt32(eventFlags[i]))
    }

    Task {
        await watcher.handleEvents(paths: paths, flags: flags)
    }
}
