import Foundation
import GRDB
import Logging

/// Periodic governance sweep for webview sessions (spec §7):
///   1. idle ≥ idleSuspendSec  → suspend (free WebContent process)
///   2. idle ≥ hardCloseSec    → close (remove session)
///   3. live count > maxLiveSessions → suspend oldest-idle until at ceiling
/// Reads webviewSessionConfig every tick so Settings changes apply live.
actor WebviewSessionSweeper {
    private let dbPool: DatabasePool
    private let logger: Logger
    private var task: Task<Void, Never>?
    private let tickInterval: TimeInterval = 30.0

    init(dbPool: DatabasePool, logger: Logger) {
        self.dbPool = dbPool
        self.logger = logger
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64((self?.tickInterval ?? 30.0) * 1_000_000_000))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private struct Config { let idleSuspendSec: Int; let hardCloseSec: Int; let maxLiveSessions: Int }

    private func loadConfig() -> Config {
        let row: Row? = try? dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT idleSuspendSec, hardCloseSec, maxLiveSessions FROM webviewSessionConfig WHERE id = 'singleton'")
        }
        return Config(
            idleSuspendSec: Int((row?["idleSuspendSec"] as Int64?) ?? 300),
            hardCloseSec: Int((row?["hardCloseSec"] as Int64?) ?? 1800),
            maxLiveSessions: Int((row?["maxLiveSessions"] as Int64?) ?? 8))
    }

    private func tick() async {
        let cfg = loadConfig()
        await MainActor.run {
            let vm = InteractiveSessionsViewModel.shared
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let webs = vm.tabs.filter { $0.kind == .webview }

            // 1 & 2: idle-based suspend / hard-close.
            for tab in webs {
                // The focused session is never idle-evicted (user is watching it).
                if tab.id == vm.activeTabId { continue }
                let idleSec = Int((now - tab.lastActivityAt) / 1000)
                if idleSec >= cfg.hardCloseSec {
                    vm.closeTab(id: tab.id)
                } else if idleSec >= cfg.idleSuspendSec, tab.lifecycle == .live {
                    vm.suspendTab(id: tab.id)
                }
            }

            // 3: ceiling — suspend oldest-idle live sessions beyond maxLiveSessions.
            var live = vm.tabs.filter { $0.kind == .webview && $0.lifecycle == .live }
            if live.count > cfg.maxLiveSessions {
                live.sort { $0.lastActivityAt < $1.lastActivityAt }   // oldest-idle first
                let overflow = live.count - cfg.maxLiveSessions
                for tab in live.prefix(overflow) where tab.id != vm.activeTabId {
                    vm.suspendTab(id: tab.id)
                }
            }
        }
    }
}
