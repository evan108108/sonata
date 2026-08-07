import Foundation
import Logging

/// Prunes reproducible and abandoned state under `~/.sonata`, and keeps the S3
/// lifecycle rules in step with local retention.
///
/// Runs as phase one of the nightly lifecycle, *before* the archive phase, so
/// the tree tarball never carries the bytes we are about to delete. Order is
/// load-bearing, not incidental: reverse it and the 44 GB of review workspaces
/// this prunes would land in S3 first (ADA-483).
///
/// Every deletion here has a stated rule and a log line. Nothing is removed on a
/// heuristic — a workspace is stale only if nothing inside it was touched inside
/// the retention window, and a worktree is removed only when git itself confirms
/// there is nothing left to lose.
actor CleanupManager {
    struct Summary: Sendable {
        var workspacesRemoved = 0
        var workspacesKept = 0
        var worktreesRemoved = 0
        var worktreesSkipped = 0
        var localBackupsRemoved = 0
        var bytesFreed: Int64 = 0
        var s3LifecycleUpdated = false

        var freedGB: String { String(format: "%.2f", Double(bytesFreed) / 1_073_741_824) }
    }

    private let logger = Logger(label: "sonata.cleanup")
    private let config: LifecycleConfig
    private let dataDir: String

    /// Deletions are refused unless the target sits under this prefix. A guard
    /// against a malformed path ever reaching `rm -rf`.
    private var deletionRoot: String { dataDir }

    private static let gitBinary = "/usr/bin/git"
    private static let findBinary = "/usr/bin/find"
    private static let duBinary = "/usr/bin/du"
    private static let rmBinary = "/bin/rm"
    private static let bytesPerKB: Int64 = 1024

    init(config: LifecycleConfig = LifecycleConfig(), dataDir: String = DatabaseManager.dataDirectory) {
        self.config = config
        self.dataDir = dataDir
    }

    // MARK: - Entry point

    /// `reconcileS3` exists so tests can exercise the prune phases without
    /// reaching for credentials or touching a real bucket. Production always
    /// leaves it on.
    func runCleanup(reconcileS3: Bool = true) async -> Summary {
        logger.info("CleanupManager: phase 1 (prune) starting")
        var summary = Summary()

        await pruneStaleWorkspaces(into: &summary)
        await pruneAbandonedWorktrees(into: &summary)
        pruneOldLocalBackups(into: &summary)
        if reconcileS3 {
            summary.s3LifecycleUpdated = await S3Lifecycle.reconcile(
                expiryDays: config.s3RetentionDays,
                logger: logger
            )
        }

        logger.info("""
            CleanupManager: phase 1 complete — freed=\(summary.freedGB) GB, \
            workspaces removed=\(summary.workspacesRemoved) kept=\(summary.workspacesKept), \
            worktrees removed=\(summary.worktreesRemoved) skipped=\(summary.worktreesSkipped), \
            local backups removed=\(summary.localBackupsRemoved), \
            s3 lifecycle updated=\(summary.s3LifecycleUpdated)
            """)
        return summary
    }

    // MARK: - prStar review workspaces

    /// `~/.sonata/prstar-workspaces/<owner>/<repo>/pr-<number>-<sha>/`
    ///
    /// prStar rebuilds a workspace on demand when a review runs, so anything
    /// untouched for the retention window is scratch that is not coming back.
    ///
    /// Staleness is judged by the newest mtime *inside* the directory, never the
    /// directory's own — some review flows write files without touching the
    /// parent, and trusting the parent would delete a live workspace.
    private func pruneStaleWorkspaces(into summary: inout Summary) async {
        let root = "\(dataDir)/prstar-workspaces"
        guard FileManager.default.fileExists(atPath: root) else { return }

        for workspace in workspaceDirectories(under: root) {
            if await containsFileNewerThanRetention(workspace) {
                summary.workspacesKept += 1
                continue
            }
            let freed = await directorySize(workspace)
            guard await remove(workspace) else { continue }
            summary.workspacesRemoved += 1
            summary.bytesFreed += freed
            logger.info("CleanupManager: pruned \(workspace) (stale > \(config.prstarWorkspacesRetentionDays)d, freed=\(mb(freed)) MB)")
        }
    }

    /// Walks `<root>/<owner>/<repo>/pr-*` without recursing into the checkouts
    /// themselves — those hold hundreds of thousands of files apiece.
    private func workspaceDirectories(under root: String) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        for owner in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let ownerPath = "\(root)/\(owner)"
            for repo in (try? fm.contentsOfDirectory(atPath: ownerPath)) ?? [] {
                let repoPath = "\(ownerPath)/\(repo)"
                for entry in (try? fm.contentsOfDirectory(atPath: repoPath)) ?? [] {
                    guard entry.hasPrefix("pr-") else { continue }
                    let path = "\(repoPath)/\(entry)"
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        found.append(path)
                    }
                }
            }
        }
        return found.sorted()
    }

    /// `find -print -quit` stops at the first hit, so a live workspace costs a
    /// partial walk rather than a full one.
    ///
    /// `-type f` is load-bearing. Without it `find` also tests the workspace
    /// directory itself, whose mtime moves whenever any entry is added or
    /// removed — including by a prune — so a directory could look fresh while
    /// everything inside it was months old. Contents decide, never the container.
    private func containsFileNewerThanRetention(_ path: String) async -> Bool {
        let outcome = await OffPoolProcess.run(Self.findBinary, [
            path, "-type", "f", "-mtime", "-\(config.prstarWorkspacesRetentionDays)", "-print", "-quit",
        ])
        guard let outcome, outcome.status == 0 else {
            // A find that could not run is not evidence of staleness. Keep the
            // directory — the cost of a false keep is disk, of a false delete is
            // someone's work.
            logger.warning("CleanupManager: staleness check failed for \(path) — keeping")
            return true
        }
        return !outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Abandoned git worktrees

    /// `~/.sonata/worktrees/<name>/`
    ///
    /// Removed only when the worktree is orphaned (its git admin directory is
    /// gone), or when its branch is both merged into `origin/main` and deleted
    /// upstream. Anything with uncommitted changes is skipped and logged — that
    /// is the exact shape of the loss this ticket is answering.
    private func pruneAbandonedWorktrees(into summary: inout Summary) async {
        let root = "\(dataDir)/worktrees"
        guard FileManager.default.fileExists(atPath: root) else { return }

        for name in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() {
            let path = "\(root)/\(name)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let verdict = await worktreeVerdict(path) else {
                summary.worktreesSkipped += 1
                continue
            }
            let freed = await directorySize(path)
            guard await remove(path) else {
                summary.worktreesSkipped += 1
                continue
            }
            summary.worktreesRemoved += 1
            summary.bytesFreed += freed
            logger.info("CleanupManager: pruned worktree \(path) (\(verdict.reason), freed=\(mb(freed)) MB)")

            if let repoRoot = verdict.repoRoot {
                _ = await OffPoolProcess.run(Self.gitBinary, ["-C", repoRoot, "worktree", "prune"])
            }
        }
    }

    private struct WorktreeVerdict { let reason: String; let repoRoot: String? }

    /// Returns a verdict only when the worktree is safe to delete. `nil` means
    /// keep it, and the reason is logged here rather than returned.
    private func worktreeVerdict(_ path: String) async -> WorktreeVerdict? {
        let gitPointer = "\(path)/.git"
        guard FileManager.default.fileExists(atPath: gitPointer) else {
            logger.info("CleanupManager: skipped \(path) — not a git worktree")
            return nil
        }

        // Uncommitted work is an absolute stop, checked before anything else.
        let status = await OffPoolProcess.run(Self.gitBinary, ["-C", path, "status", "--porcelain"])
        guard let status, status.status == 0 else {
            logger.info("CleanupManager: skipped \(path) — git status unavailable")
            return nil
        }
        if !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("CleanupManager: skipped \(path) — uncommitted changes present")
            return nil
        }

        // `.git` in a worktree is a file pointing at the admin dir in the source
        // repo: `gitdir: /path/to/repo/.git/worktrees/<name>`.
        let pointer = (try? String(contentsOfFile: gitPointer, encoding: .utf8)) ?? ""
        let adminDir = pointer
            .split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
            .map { String($0.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces) }

        guard let adminDir else {
            logger.info("CleanupManager: skipped \(path) — unreadable gitdir pointer")
            return nil
        }
        let repoRoot = URL(fileURLWithPath: adminDir)   // …/.git/worktrees/<name>
            .deletingLastPathComponent()                // …/.git/worktrees
            .deletingLastPathComponent()                // …/.git
            .deletingLastPathComponent().path           // repo root

        if !FileManager.default.fileExists(atPath: adminDir) {
            return WorktreeVerdict(reason: "orphaned — git admin dir gone", repoRoot: nil)
        }

        let head = await OffPoolProcess.run(Self.gitBinary, ["-C", path, "symbolic-ref", "--short", "HEAD"])
        let branch = (head?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard head?.status == 0, !branch.isEmpty else {
            logger.info("CleanupManager: skipped \(path) — detached HEAD, cannot prove it is merged")
            return nil
        }

        let merged = await OffPoolProcess.run(
            Self.gitBinary, ["-C", repoRoot, "merge-base", "--is-ancestor", branch, "origin/main"]
        )
        guard merged?.status == 0 else {
            logger.info("CleanupManager: skipped \(path) — branch \(branch) not merged into origin/main")
            return nil
        }

        let remote = await OffPoolProcess.run(
            Self.gitBinary, ["-C", repoRoot, "ls-remote", "--heads", "origin", branch]
        )
        guard let remote, remote.status == 0 else {
            logger.info("CleanupManager: skipped \(path) — could not reach origin to confirm \(branch) is gone")
            return nil
        }
        guard remote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.info("CleanupManager: skipped \(path) — branch \(branch) still exists upstream")
            return nil
        }

        return WorktreeVerdict(reason: "branch \(branch) merged into origin/main and deleted upstream", repoRoot: repoRoot)
    }

    // MARK: - Local DB backups

    /// Dated local backups are redundant with S3 past the retention window.
    /// `sonata-latest.db*` is the live rotating copy and is always preserved.
    private func pruneOldLocalBackups(into summary: inout Summary) {
        let backupDir = "\(dataDir)/backups"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: backupDir) else { return }

        let cutoff = Date().addingTimeInterval(-Double(config.localRetentionDays) * 86_400)
        for name in entries.sorted() {
            guard name.hasPrefix("sonata-"), name.contains(".db") else { continue }
            guard !name.hasPrefix("sonata-latest.db") else { continue }

            let path = "\(backupDir)/\(name)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }

            let size = (attrs[.size] as? Int64) ?? 0
            guard (try? fm.removeItem(atPath: path)) != nil else {
                logger.warning("CleanupManager: failed to remove \(path)")
                continue
            }
            summary.localBackupsRemoved += 1
            summary.bytesFreed += size
            logger.info("CleanupManager: pruned \(path) (older than \(config.localRetentionDays)d, freed=\(mb(size)) MB)")
        }
    }

    // MARK: - Helpers

    private func directorySize(_ path: String) async -> Int64 {
        guard let outcome = await OffPoolProcess.run(Self.duBinary, ["-sk", path]),
              outcome.status == 0,
              let kb = Int64(outcome.text.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "")
        else { return 0 }
        return kb * Self.bytesPerKB
    }

    /// Refuses any path outside the data directory, then deletes off the
    /// cooperative pool — a review workspace is ~90 k files.
    private func remove(_ path: String) async -> Bool {
        let resolved = URL(fileURLWithPath: path).standardized.path
        guard resolved.hasPrefix(deletionRoot + "/"), resolved != deletionRoot else {
            logger.error("CleanupManager: refused to delete \(resolved) — outside \(deletionRoot)")
            return false
        }
        let outcome = await OffPoolProcess.run(Self.rmBinary, ["-rf", resolved])
        if outcome?.status != 0 {
            logger.error("CleanupManager: rm failed for \(resolved) (status \(outcome?.status ?? -1))")
            return false
        }
        return true
    }

    private func mb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}
