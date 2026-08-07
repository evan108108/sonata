import Foundation

/// Tunables for the nightly lifecycle run — prune, then archive, then upload.
///
/// These live in one place because the two halves have to agree: `CleanupManager`
/// deletes what `BackupManager` must not archive, and the S3 expiry has to match
/// the local retention or the two copies drift out of step.
struct LifecycleConfig: Sendable {
    /// Whether the tree archive runs at all. The DB backup is unconditional —
    /// it predates this config and is the last line of defence.
    var treeBackupEnabled: Bool = true

    /// `tar --exclude` patterns, applied to an archive rooted at the data
    /// directory (entries are stored as `./plugins/...`).
    var treeExcludes: [String] = LifecycleConfig.defaultTreeExcludes

    /// How long a dated local backup survives in `~/.sonata/backups`.
    var localRetentionDays: Int = 2

    /// Expiry written to the bucket's lifecycle rules. Kept equal to
    /// `localRetentionDays` by default so both copies age out together.
    var s3RetentionDays: Int = 2

    /// How long an untouched prStar review workspace survives.
    var prstarWorkspacesRetentionDays: Int = 2

    static let s3Bucket = "enginable-sonata-backups"
    static let s3Region = "us-east-1"
    /// Nightly gzipped `sonata.db` dumps.
    static let s3BackupsPrefix = "backups/"
    /// Tree archives, new in ADA-483.
    static let s3TreePrefix = "tree/"

    /// Excluded because each entry is either reproducible (rebuilt from git, a
    /// model download, or a search index) or ephemeral scratch. Everything NOT
    /// listed here is state we could not reconstruct — `plugins/` above all,
    /// which is what this whole ticket exists to protect (ADA-483).
    ///
    /// Patterns come in two shapes because bsdtar matches against the stored
    /// path: `./name` pins a directory to the archive root, `*/name` catches it
    /// at any depth. Verified against bsdtar: a matching directory prunes its
    /// entire subtree, so no companion `./name/*` pattern is needed.
    static let defaultTreeExcludes: [String] = [
        "./prstar-workspaces",   // 44 GB of per-PR review checkouts, rebuilt on demand
        "./bin",                 // 5 GB of LLM binaries, re-downloadable
        "./worktrees",           // ephemeral, reproducible from git
        "./models",              // model weights, re-downloadable
        "./meili-data",          // search index, rebuildable from sonata.db
        "./backups",             // don't archive the archives
        "./logs",
        "*/logs",
        "./.build",              // Swift build artifacts
        "*/.build",
        "*/node_modules",        // inside plugin dirs
        "*.log",
    ]
}

/// Which half of the backup to run. `POST /api/backup?scope=` selects it.
enum BackupScope: String, Sendable {
    case db
    case tree
    case both

    init(param: String?) {
        self = BackupScope(rawValue: param?.lowercased() ?? "") ?? .both
    }

    var includesDB: Bool { self == .db || self == .both }
    var includesTree: Bool { self == .tree || self == .both }
}
