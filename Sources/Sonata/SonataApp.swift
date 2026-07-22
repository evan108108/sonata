import Foundation
import SwiftUI
import Hummingbird
import HummingbirdWebSocket
import GRDB
import Logging
import SwiftTerm

// MARK: - Studio dbPool environment key (impl-spec §10 Diff E)

private struct DBPoolKey: EnvironmentKey {
    static let defaultValue: DatabasePool? = nil
}

extension EnvironmentValues {
    var dbPool: DatabasePool? {
        get { self[DBPoolKey.self] }
        set { self[DBPoolKey.self] = newValue }
    }
}

// MARK: - App Entry Point

/// Port for the Sonata HTTP server, configurable via SONATA_PORT env var.
let sonataPort: Int = SonataInstance.port

/// Ensure sonata-bridge MCP server is registered in ~/.claude/mcp.json, and
/// scrub any stale `memory` stdio entry (now redundant — sonata-bridge serves
/// the full ActionRegistry surface alongside the worker shim tools, per the
/// mcp-unify-worker-surface plan §Step 6). Called on startup so every Claude
/// Code session has Sona's memory through one HTTP transport.
func ensureGlobalMCPServers() {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser

    // Phase D — COMPLETE as of 2026-07-21. Neither mem-server.ts nor
    // sonata-bridge.ts survives; the in-app HTTP+SSE server at /mcp is the
    // only transport. Both stdio proxies are gone from ~/.sonata/mcp (dir
    // removed), and the bundled `Sources/Sonata/Resources/mcp` resource went
    // with them (its `.copy` entry is out of Package.swift).
    //
    // ~/.sonata/mcp/sonata-bridge.ts was deleted first, after confirming no
    // process ran it and that every session config points at the HTTP
    // transport. Leaving it on disk had a real cost — it read as live code,
    // and a heartbeat field was written into it that consequently never
    // reached the database.
    //
    // mem-server.ts was held back one round because the on-disk copy looked
    // like a divergent hand-edit: it carried an afk_register sessionId
    // auto-injection the bundled copy lacked. It was not divergent. The file
    // was byte-identical to `git show 96d96c1:…/Resources/mcp/mem-server.ts`
    // — a stale build artifact of a tracked commit, so nothing was unique to
    // it. And the behavior it carried was already dead: afk_register itself
    // was retired in 89b1fc9 (2026-06-08, "route by sessionId, retire tokens
    // and AFKRegistry entirely"). AFK now routes on sessionId via
    // sonata_whoami + global_afk_set/_status, and the live 240-tool surface
    // has no afk_register at all. Porting the injection would have
    // resurrected a helper for a tool that no longer exists.
    //
    // `serversToRemove` below is what makes this irreversible in the right
    // direction: any lingering `memory` stdio entry — the only config shape
    // that could ever spawn mem-server.ts — is scrubbed from both Claude
    // config files on every startup.

    // sonata-bridge: HTTP+SSE entry pointing at /mcp (no path), with
    // the bearer = ${SONA_SESSION_ID} env var. Claude substitutes the
    // env var at request time → the bearer becomes the sessionKey.
    //   - sona-launched sessions: SONA_SESSION_ID set by the sona()
    //     shell function to a fresh UUID → bearer == sessionKey == claude
    //     session id.
    //   - non-sona launches: env var unset → bearer arrives as the
    //     literal "${SONA_SESSION_ID}" → Sonata mints anon-XXX and
    //     pushes the sonata_identify handshake notification.
    // See ~/.sonata/wiki/sonata/mcp-identity.md.
    let requiredServers: [String: [String: Any]] = [
        "sonata-bridge": [
            "type": "http",
            "url": "http://localhost:\(sonataPort)/mcp",
            "headers": [
                "Authorization": "Bearer ${SONA_SESSION_ID}",
            ],
        ],
    ]

    // Names whose presence is now incorrect — drop on encounter. Was added
    // to ~/.claude/mcp.json by previous Sonata releases; left intact it
    // creates a double-namespace footgun (mcp__memory__mem_store AND
    // mcp__sonata-bridge__mem_store both resolve to the same action).
    let serversToRemove: Set<String> = ["memory"]

    let configPaths = [
        home.appendingPathComponent(".claude/mcp.json"),   // Claude Code
        home.appendingPathComponent(".claude.json"),        // Claude Desktop
    ]

    for configPath in configPaths {
        do {
            var json: [String: Any] = [:]
            if let data = try? Data(contentsOf: configPath) {
                json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            var mcpServers = json["mcpServers"] as? [String: Any] ?? [:]

            var changed = false
            for name in serversToRemove where mcpServers[name] != nil {
                mcpServers.removeValue(forKey: name)
                changed = true
                sonataFileLog("MCP setup: removed stale '\(name)' from \(configPath.lastPathComponent)")
            }
            for (name, config) in requiredServers {
                if let existing = mcpServers[name] as? [String: Any],
                   (existing["url"] as? String) == (config["url"] as? String) {
                    continue  // Already correct
                }
                mcpServers[name] = config
                changed = true
                sonataFileLog("MCP setup: set '\(name)' in \(configPath.lastPathComponent)")
            }

            if changed {
                json["mcpServers"] = mcpServers
                let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try output.write(to: configPath)
                sonataFileLog("MCP setup: updated \(configPath.lastPathComponent)")
            }
        } catch {
            sonataFileLog("MCP setup: failed to update \(configPath.lastPathComponent) — \(error)")
        }
    }
}

/// Install / refresh the `sona` shell launcher in ~/.zshrc.
///
/// The launcher is a small zsh function that mints (or reuses, for
/// --resume) a UUID per claude session and sets SONA_SESSION_ID in the
/// claude process env. Claude's HTTP MCP client substitutes ${SONA_SESSION_ID}
/// into the bearer header from ~/.claude.json, so the bearer equals
/// the session id — see ~/.sonata/wiki/sonata/mcp-identity.md.
///
/// Managed via begin/end markers (same pattern as rbenv, pyenv, conda).
/// On every Sonata boot:
///   - if the block is present and its body matches what we want → no-op
///   - if the block is present but drifted (older version, edited by
///     hand, etc.) → replace in place
///   - if the block is absent → append to the end of ~/.zshrc
/// Inside the block we run `unalias sona 2>/dev/null` so any legacy
/// `alias sona=…` defined earlier in the file is wiped — the function
/// still wins because it's defined last.
///
/// On each modification we write the previous ~/.zshrc to
/// ~/.zshrc.sonata-backup-<epoch> as a recoverable snapshot.
func ensureSonaLauncher() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let zshrc = home.appendingPathComponent(".zshrc")
    let beginMarker = "# >>> sona-launcher (managed by Sonata — do not edit) >>>"
    let endMarker = "# <<< sona-launcher <<<"
    let expectedBlock = """
        \(beginMarker)
        # Sonata-managed `sona` launcher. Mints a per-session UUID and
        # sets SONA_SESSION_ID so claude's HTTP MCP client substitutes
        # it into the sonata-bridge bearer header in ~/.claude/mcp.json.
        # See ~/.sonata/wiki/sonata/mcp-identity.md.
        unalias sona 2>/dev/null
        sona() {
            local sid
            local resuming=0
            local i
            for ((i=1; i<=$#; i++)); do
                case "${@[i]}" in
                    --resume|--continue)
                        resuming=1
                        if [[ "${@[i]}" == "--resume" && $((i+1)) -le $# && "${@[i+1]}" != -* ]]; then
                            sid="${@[i+1]}"
                        fi
                        ;;
                esac
            done
            : ${sid:=$(uuidgen | tr 'A-Z' 'a-z')}
            # Pre-warm Sonata's session registry so the dashboard shows
            # this session immediately. Without this, claude's HTTP MCP
            # client connects LAZILY on first tool call — meaning a fresh
            # `sona` session might not appear in "Connected" for minutes.
            # The bearer matches what claude will use; same session entry.
            curl -s --max-time 1 \\
                -H "Authorization: Bearer $sid" \\
                -H "Content-Type: application/json" \\
                -d '{"jsonrpc":"2.0","method":"ping","id":0}' \\
                http://localhost:3211/mcp >/dev/null 2>&1 || true
            # On --resume, omit --session-id: claude rejects the combo
            # unless --fork-session is also set. The resumed id is already
            # pinned by --resume, and SONA_SESSION_ID still carries the
            # bearer for the MCP client.
            if (( resuming )); then
                SONA_SESSION_ID=$sid CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 \\
                    $HOME/bin/claude-patched \\
                        --dangerously-skip-permissions \\
                        --dangerously-load-development-channels server:sonata-bridge \\
                        "$@"
            else
                SONA_SESSION_ID=$sid CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 \\
                    $HOME/bin/claude-patched \\
                        --session-id $sid \\
                        --dangerously-skip-permissions \\
                        --dangerously-load-development-channels server:sonata-bridge \\
                        "$@"
            fi
        }
        \(endMarker)
        """

    let current: String
    do {
        current = try String(contentsOf: zshrc, encoding: .utf8)
    } catch {
        // No ~/.zshrc → don't create one. Some shells use ~/.zprofile,
        // others none at all. Logging is enough.
        sonataFileLog("sona-launcher: ~/.zshrc not present — skipping (sona alias not managed)")
        return
    }

    let newContent: String
    if let beginRange = current.range(of: beginMarker),
       let endRange = current.range(of: endMarker, range: beginRange.upperBound..<current.endIndex) {
        let existing = String(current[beginRange.lowerBound..<endRange.upperBound])
            + endMarker.suffix(0)  // include end marker (already in range)
        let blockRange = beginRange.lowerBound..<current.index(endRange.lowerBound, offsetBy: endMarker.count)
        let existingFull = String(current[blockRange])
        if existingFull == expectedBlock {
            return  // already up to date
        }
        newContent = current.replacingCharacters(in: blockRange, with: expectedBlock)
        sonataFileLog("sona-launcher: ~/.zshrc block drifted — refreshing")
        _ = existing  // suppress unused
    } else {
        let trimmed = current.hasSuffix("\n") ? current : current + "\n"
        newContent = trimmed + "\n" + expectedBlock + "\n"
        sonataFileLog("sona-launcher: appending block to ~/.zshrc")
    }

    let backup = home.appendingPathComponent(
        ".zshrc.sonata-backup-\(Int(Date().timeIntervalSince1970))")
    try? current.write(to: backup, atomically: true, encoding: .utf8)
    do {
        try newContent.write(to: zshrc, atomically: true, encoding: .utf8)
    } catch {
        sonataFileLog("sona-launcher: write failed — \(error). backup at \(backup.path)")
    }
}

/// Ensure ~/.sonata/worker/ and ~/.sonata/supervisor/ directories exist with CLAUDE.md files.
/// Copies defaults from the app bundle if not present. Does not overwrite existing files.
func ensureRoleDirectories() {
    let fm = FileManager.default
    let sonataDir = URL(fileURLWithPath: SonataInstance.dataDirectory)

    for role in ["worker", "supervisor"] {
        let roleDir = sonataDir.appendingPathComponent(role)
        let claudeMdDest = roleDir.appendingPathComponent("CLAUDE.md")

        // Create directory
        try? fm.createDirectory(at: roleDir, withIntermediateDirectories: true)

        // Copy CLAUDE.md from bundle if not present
        if !fm.fileExists(atPath: claudeMdDest.path) {
            if let sourceURL = Bundle.module.url(forResource: "CLAUDE", withExtension: "md", subdirectory: role) {
                try? fm.copyItem(at: sourceURL, to: claudeMdDest)
                sonataFileLog("Role setup: copied \(role)/CLAUDE.md from bundle")
            } else {
                sonataFileLog("Role setup: \(role)/CLAUDE.md not found in bundle")
            }
        }
    }
}

/// Bring up the sidecar subsystem: load user config, register the sidecars this
/// build ships, install spend tracking, and spawn everything not switched off.
///
/// Order is load-bearing. `SidecarConfigStore.load()` must complete before
/// registration, because registration folds the stored config into the
/// immutable `Sidecar` value. Registering first would bake in framework
/// defaults and silently ignore the user's tuned tier and cap.
///
/// Every failure here is logged and survived rather than thrown: sidecars are
/// an assist, and a machine that cannot run one should still boot Sonata.
func bootSidecars(dbPool: DatabasePool, logger: Logger) async {
    do {
        try SidecarConfigStore.shared.load()
    } catch {
        // A corrupt config file is worth shouting about, but it must not cost
        // the user their sidecars — carry on with defaults.
        logger.error("Sidecar config failed to load (\(error)) — continuing on defaults")
    }

    guard let skillPath = MemorySidecarRegistration.bundledSkillPath() else {
        logger.error("""
            Sidecar 'memory' not registered: SKILL.md missing from the app \
            bundle. Check that Package.swift still copies \
            Sonata/Resources/sidecars.
            """)
        return
    }

    // Two-step so `config(for:)` can seed from the registration's own defaults
    // when the user has never opened the panel, then fold the result back in.
    let baseline = MemorySidecarRegistration.sidecar(skillPath: skillPath, config: .default)
    let config = SidecarConfigStore.shared.config(for: baseline)
    let memorySidecar = MemorySidecarRegistration.sidecar(skillPath: skillPath, config: config)

    do {
        try SidecarRegistry.shared.register(memorySidecar)
    } catch {
        logger.error("Sidecar 'memory' failed to register: \(error)")
        return
    }

    let tracker = SidecarSpendTracker()
    SidecarSpendRegistry.shared.install(tracker)

    let lifecycle = SidecarLifecycle(
        dbPool: dbPool,
        logger: logger,
        spawner: SidecarSpawnerFactory.make(logger: logger)
    )
    SidecarRuntime.shared.install(lifecycle: lifecycle, tracker: tracker)

    // What to actually DO when a sidecar blows its budget. The tracker decides
    // *that* one should be throttled and deliberately holds no reference to the
    // config store or the lifecycle; this closure is the other half.
    //
    // Both branches persist before they act on the session. A tier drop that
    // rotated first and then failed to write would come back at the old tier on
    // the next launch and immediately overspend again — the throttle has to
    // survive a restart to mean anything.
    await tracker.setApplyThrottle { [weak lifecycle] name, action in
        guard let sidecar = SidecarRegistry.shared.lookup(byName: name) else { return }

        let newTier: SidecarBudgetTier
        switch action {
        case .none:
            return
        case .dropTier:
            // Nowhere to drop to means the ladder bottomed out; `.off` is
            // already the floor and stopping it again is a no-op.
            guard let lower = sidecar.budgetTier.nextLower else { return }
            newTier = lower
        case .off:
            newTier = .off
        }

        let throttled = Sidecar(
            name: sidecar.name,
            skillPath: sidecar.skillPath,
            eventTypes: sidecar.eventTypes,
            budgetTier: newTier,
            subscriptionCapPct: sidecar.subscriptionCapPct,
            triggers: sidecar.triggers,
            rotationThreshold: sidecar.rotationThreshold,
            contextWindowTokens: sidecar.contextWindowTokens
        )

        do {
            try SidecarRegistry.shared.update(throttled)
        } catch {
            logger.error("Sidecar '\(name)' throttle could not update the registry: \(error)")
            return
        }

        // Persist so the drop outlives this launch. A write failure is logged
        // and swallowed: the in-memory tier has already changed, so a read-only
        // disk degrades to "the throttle forgets on restart" rather than
        // "the throttle does not apply".
        var stored = SidecarConfigStore.shared.config(forName: name)
        stored.tier = newTier
        do {
            try SidecarConfigStore.shared.setConfig(stored, forName: name)
        } catch {
            logger.error("Sidecar '\(name)' throttled to \(newTier.rawValue) but config did not persist: \(error)")
        }

        // `.off` stands the session down for good; a tier drop rotates, because
        // the tier is read when a session builds its prompts and only a fresh
        // one will pick up the new value.
        if newTier == .off {
            logger.warning("Sidecar '\(name)' hit its spend cap — stopping it")
            await lifecycle?.stop(throttled)
        } else {
            logger.warning("Sidecar '\(name)' over budget — dropping to \(newTier.rawValue) and rotating")
            await lifecycle?.rotate(throttled)
        }
    }

    await lifecycle.spawnAllRegistered()

    // Safe to sample context from here on: the monitor reads
    // `workers.currentContextTokens`, the last assistant turn's usage, which is
    // an actual measure of what the next turn carries. It replaced a cumulative
    // per-event sum that read in the thousands of percent and would have
    // rotated the sidecar on its first multi-turn event.
    //
    // The `rotate_me` events this posts are now consumed: the sidecar handles
    // one like any other event and calls `complete_event`, and the branch in
    // `worker_event_complete` turns that completion into
    // `SidecarLifecycle.rotate(_:)`. Any that piled up before that handler
    // existed are still in `workerEvents` and rotate on their next push —
    // deferred, never lost, as intended.
    await lifecycle.startMonitoring()

    let running = await lifecycle.runningSidecarNames().sorted()
    if running.isEmpty {
        logger.info("Sidecars registered but none running (tier=off, or spawn failed above)")
    } else {
        logger.info("Sidecars running: \(running.joined(separator: ", "))")
    }
}

/// Deploy Sona's bundled Claude Code skills to ~/.claude/skills/. Currently
/// just the `/afk` skill because that's the one tied directly to Sonata
/// runtime (channel-push from EmailHandler). Always overwrites so the skill
/// stays in sync with the Sonata version that owns the wire format.
///
/// Add new skills here by:
///   1. Drop SKILL.md (plus any sibling files) into
///      Sources/Sonata/Resources/skills/<name>/
///   2. Append the slug to the `skills` array below.
func ensureBundledSkills() {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let skillsRoot = home.appendingPathComponent(".claude/skills")
    try? fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)

    let skills = ["afk"]
    for slug in skills {
        let destDir = skillsRoot.appendingPathComponent(slug)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destFile = destDir.appendingPathComponent("SKILL.md")
        guard let sourceURL = Bundle.module.url(
            forResource: "SKILL", withExtension: "md", subdirectory: "skills/\(slug)"
        ) else {
            sonataFileLog("Skill setup: SKILL.md not found in bundle for skills/\(slug)")
            continue
        }
        try? fm.removeItem(at: destFile)
        do {
            try fm.copyItem(at: sourceURL, to: destFile)
            sonataFileLog("Skill setup: deployed skills/\(slug)/SKILL.md to ~/.claude/skills/")
        } catch {
            sonataFileLog("Skill setup: failed to copy skills/\(slug)/SKILL.md — \(error)")
        }
    }
}

/// Redirect stdout + stderr to ~/Library/Logs/Sonata.log so any `print(...)`,
/// FileHandle.standardError write, or runtime crash trace lands in the same
/// file the in-app Logs viewer tails. Without this, Finder-launched Sonata
/// silently drops every print() — making the LogsView miss most runtime errors
/// from the worker pool, inspector, and ad-hoc debug print sites.
///
/// Gated on `isatty(stderr)`: when stderr is already a terminal (`swift run`,
/// Xcode console, ssh shell) we leave it alone so console output keeps working.
/// When stderr is *not* a TTY (Finder launch, double-clicked .app) we redirect
/// to the log file so the LogsView is the source of truth.
private var stderrRedirectInstalled = false
func installSonataStdoutRedirect() {
    guard !stderrRedirectInstalled else { return }
    stderrRedirectInstalled = true

    // If stderr is already a TTY, the developer is running from a terminal and
    // wants console output. Skip the redirect.
    if isatty(fileno(stderr)) != 0 { return }

    let logsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logURL = logsDir.appendingPathComponent("Sonata.log")

    // Boot-time rotation: if Sonata.log is over the cap, move it aside to
    // Sonata.log.1 (overwriting any older rotation) and start fresh. Sonata
    // restarts often enough that a once-per-boot check is sufficient — we
    // don't bother with a mid-session timer.
    let rotateCapBytes: UInt64 = 200 * 1024 * 1024
    let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))
        .flatMap { ($0[.size] as? NSNumber)?.uint64Value } ?? 0
    if size > rotateCapBytes {
        let prev = logsDir.appendingPathComponent("Sonata.log.1")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: logURL, to: prev)
    }

    let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    // Line-buffer so prints land in the file promptly instead of waiting for a
    // 4 KB flush — the LogsView polls every 500 ms and we want it lively.
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IOLBF, 0)
    dup2(fd, fileno(stdout))
    dup2(fd, fileno(stderr))
    close(fd)
}

/// Append a line to ~/Library/Logs/Sonata.log so errors are visible when the
/// app is launched from the Finder (where stderr is discarded).
func sonataFileLog(_ line: String) {
    let logsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let logURL = logsDir.appendingPathComponent("Sonata.log")
    let ts = ISO8601DateFormatter().string(from: Date())
    let entry = "[\(ts)] \(line)\n"
    if let data = entry.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

/// Scan for pool workers stuck offline past the resurrection cutoff and
/// respawn a fresh worker into each abandoned slot. Called from the
/// periodic ghost-reaper Task on the same 5-min cadence.
///
/// Row-level criteria (all must hold):
///   - status = 'offline' (escalation ladder classified this as dead)
///   - lastHeartbeat >= 90 min ago (well past any transient MCP reconnect
///     and the 5-min escalation grace)
///   - currentEventId IS NULL (no active work — the escalation ladder
///     ALREADY reaped the ones with active events, so anything still
///     sitting here is by definition "worker dead, nothing to reassign")
///   - sessionLabel matches 'sona-worker-*' (pool slots only)
///   - workerId is NOT in the pgrep live-worker set (belt against
///     deleting a row whose process is somehow still alive)
///
/// For each survivor: DELETE the row, then on MainActor call
/// `WorkerManager.attemptSlotResurrection(sessionLabel:)` which respects
/// `userRemovedLabels` and appends a fresh Worker into the slot.
///
/// Why 90 min and not longer/shorter: 5-min escalation grace is the
/// longest legitimate "transient offline" window we have. 90 min is
/// well past that plus any conceivable MCP reconnect or heartbeat gap.
/// Shorter would flake on legitimate briefly-offline workers; longer
/// would leave the pool below configured size for longer than the
/// operator wants.
private func resurrectAbandonedPoolSlots(dbPool: DatabasePool, logger: Logger) async {
    let cutoffMs = nowMs() - 90 * 60 * 1000
    struct StaleRow {
        let workerId: String
        let sessionLabel: String
    }
    let candidates: [StaleRow]
    do {
        candidates = try await dbPool.read { db -> [StaleRow] in
            try Row.fetchAll(db, sql: """
                SELECT workerId, sessionLabel FROM workers
                WHERE status = 'offline'
                  AND lastHeartbeat < ?
                  AND (currentEventId IS NULL OR currentEventId = '')
                  AND sessionLabel GLOB 'sona-worker-*'
            """, arguments: [cutoffMs]).compactMap { row in
                guard let wid = row["workerId"] as? String,
                      let label = row["sessionLabel"] as? String else { return nil }
                return StaleRow(workerId: wid, sessionLabel: label)
            }
        }
    } catch {
        logger.warning("resurrectAbandonedPoolSlots: query failed: \(error.localizedDescription)")
        return
    }
    guard !candidates.isEmpty else { return }

    // Pgrep-based live-process guard. If a claude process is still up
    // for this workerId, the row is a stale-status lie, not a dead
    // worker — DO NOT delete or respawn. GhostWorkerReaper's periodic
    // run on the same cadence handles unregistered live processes; this
    // path is only for genuinely-dead workers.
    let liveWorkerIds = Set(
        GhostWorkerReaper.enumerateWorkerProcesses().map { $0.workerId }
    )
    for row in candidates {
        if liveWorkerIds.contains(row.workerId) {
            logger.info("resurrectAbandonedPoolSlots: skipping \(row.sessionLabel) workerId=\(row.workerId) — process still alive")
            continue
        }
        // Delete the stale row THEN respawn. Order matters:
        // addWorker(label:) registers a fresh Worker with a fresh
        // workerId; the new registration's predecessor-cleanup would
        // delete this row anyway, but deleting first keeps the DB
        // clean during the ~5s spawn→register handshake.
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "DELETE FROM workers WHERE workerId = ?",
                    arguments: [row.workerId]
                )
            }
        } catch {
            logger.warning("resurrectAbandonedPoolSlots: delete failed for \(row.workerId): \(error.localizedDescription)")
            continue
        }
        let spawned = await MainActor.run {
            WorkerManager.shared.attemptSlotResurrection(sessionLabel: row.sessionLabel)
        }
        logger.info("resurrectAbandonedPoolSlots: \(row.sessionLabel) workerId=\(row.workerId) — deleted stale row, spawned=\(spawned)")
    }
}

/// Poll the local HTTP server until it responds or the timeout expires.
/// Blocks the current thread — intended to be called from init() so the
/// server is listening before the SwiftUI window loads any webview.
func waitForSonataHTTP(port: Int, timeoutSeconds: Double = 5.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    let url = URL(string: "http://127.0.0.1:\(port)/api/system/status")!
    while Date() < deadline {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                ok = true
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 0.5)
        if ok { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

/// Raise the process file-descriptor soft limit toward the hard limit.
///
/// macOS launches GUI apps with an RLIMIT_NOFILE soft limit of 256. Under
/// multi-worker + SSE load Sonata hit that ceiling on 2026-07-17: an fcntl()
/// on a freshly-accepted socket failed with EMFILE, SwiftNIO's ServiceGroup
/// treated the HTTP server as finished-unexpectedly and tore it down for good
/// (no auto-restart), and every subsequent connection timed out. Raising the
/// limit at startup is the primary fix — it removes the trigger entirely.
///
/// The hard limit is effectively unlimited, but the kernel still caps a single
/// process at kern.maxfilesperproc, so setrlimit above that fails. Step the
/// request down until it takes rather than giving up on the first failure.
/// `RLIM_INFINITY` is a C macro Swift can't import (the SDK marks it
/// "structure not supported"), so spell out its value: (1 << 63) - 1.
private let rlimInfinity: rlim_t = (rlim_t(1) << 63) - 1

/// Raised by the supervised HTTP server task when it has restarted the server
/// more times than its budget allows — a signal that the failure is not a
/// transient fd spike and should surface as a fatal log rather than hot-loop.
enum HTTPServerSupervisorError: Error {
    case restartBudgetExhausted(Int)
    case livenessLost(Int)
}

/// Poll `/api/ping` until the server stops answering, then throw.
///
/// The 2026-07-17 supervisor only reacts when SwiftNIO's ServiceGroup reports
/// the HTTP service finished. That misses the failure mode we have actually hit
/// twice: the listener binds, logs "Server started and listening", and then
/// refuses every connection for the rest of the process's life while
/// `runService()` sits there never returning. On 2026-07-21 that cost 11
/// minutes — no worker registered, EmailHandler could not enqueue its own
/// alert — and only a manual quit+relaunch fixed it. Racing the server against
/// an active liveness probe turns that silent death into an ordinary restart.
///
/// Deliberately tolerant: a `graceSeconds` warmup before the first probe, and
/// `failuresBeforeRestart` consecutive misses required, so a slow boot or one
/// dropped connection never bounces a healthy server.
func httpLivenessWatchdog(
    port: Int,
    graceSeconds: TimeInterval = 30,
    probeInterval: TimeInterval = 15,
    failuresBeforeRestart: Int = 3
) async throws {
    try await Task.sleep(for: .seconds(graceSeconds))
    let url = URL(string: "http://127.0.0.1:\(port)/api/ping")!
    var consecutiveFailures = 0
    while !Task.isCancelled {
        var alive = false
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            let (data, response) = try await URLSession(configuration: config).data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["pong"] as? Bool == true {
                alive = true
            }
        } catch {
            alive = false
        }
        if Task.isCancelled { return }
        if alive {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
            sonataFileLog("HTTP liveness: /api/ping unanswered (\(consecutiveFailures)/\(failuresBeforeRestart))")
            if consecutiveFailures >= failuresBeforeRestart {
                throw HTTPServerSupervisorError.livenessLost(consecutiveFailures)
            }
        }
        try await Task.sleep(for: .seconds(probeInterval))
    }
}

/// Block until nothing holds `port`, or `attempts` seconds elapse.
///
/// Rebinding after a wedge races the outgoing listener's teardown; without this
/// the fresh `Application` can hit EADDRINUSE and burn a restart from the
/// budget for no reason. Extracted from the one-shot startup probe so the
/// restart path gets the same courtesy.
@discardableResult
func waitForPortFree(_ port: Int, attempts: Int = 10) async -> Bool {
    for attempt in 1...attempts {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var optval: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        close(sock)
        if bindResult == 0 {
            if attempt > 1 { sonataFileLog("HTTP port \(port) free after \(attempt) attempts") }
            return true
        }
        sonataFileLog("HTTP port \(port) busy, waiting... (attempt \(attempt)/\(attempts))")
        try? await Task.sleep(for: .seconds(1))
    }
    return false
}

@discardableResult
func raiseFileDescriptorLimit(to target: rlim_t) -> Bool {
    var lim = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else {
        sonataFileLog("Sonata init: getrlimit(RLIMIT_NOFILE) failed — leaving fd limit at default")
        return false
    }
    let hardCeiling: rlim_t = lim.rlim_max == rlimInfinity ? target : min(target, lim.rlim_max)
    guard hardCeiling > lim.rlim_cur else {
        sonataFileLog("Sonata init: RLIMIT_NOFILE already \(lim.rlim_cur) (>= target \(target)) — no change")
        return true
    }
    let stepDown: rlim_t = 1024
    var desired = hardCeiling
    while desired > lim.rlim_cur {
        var newLim = lim
        newLim.rlim_cur = desired
        if setrlimit(RLIMIT_NOFILE, &newLim) == 0 {
            let hardDesc = lim.rlim_max == rlimInfinity ? "unlimited" : String(lim.rlim_max)
            sonataFileLog("Sonata init: raised RLIMIT_NOFILE soft limit \(lim.rlim_cur) → \(desired) (hard \(hardDesc))")
            return true
        }
        desired = desired > lim.rlim_cur + stepDown ? desired - stepDown : lim.rlim_cur
    }
    sonataFileLog("Sonata init: could not raise RLIMIT_NOFILE above \(lim.rlim_cur)")
    return false
}

/// Set FD_CLOEXEC on any TCP listen socket bound to `port`.
///
/// Sonata spawns worker/plugin child processes via fork+exec (SwiftTerm's
/// forkpty for workers). fork() copies every open descriptor; only those
/// carrying FD_CLOEXEC are closed at exec(). If the HTTP acceptor socket lacks
/// the flag, each child inherits a copy — so after the server tears down the
/// port stays in LISTEN with no acceptor (every connection times out) and a
/// rebind hits EADDRINUSE. That is exactly what pinned :port on 2026-07-17.
///
/// fcntl(F_SETFD) is idempotent, so this is harmless belt-and-suspenders if
/// NIO already set the flag. Best-effort: failures are logged, never fatal.
func setCloseOnExecOnListenSockets(port: Int) {
    var lim = rlimit()
    let maxFD: Int32
    if getrlimit(RLIMIT_NOFILE, &lim) == 0, lim.rlim_cur != rlimInfinity {
        maxFD = Int32(min(lim.rlim_cur, 65536))
    } else {
        maxFD = 4096
    }
    var patched = 0
    var fd: Int32 = 3   // skip stdin/stdout/stderr
    while fd < maxFD {
        defer { fd += 1 }
        var st = stat()
        guard fstat(fd, &st) == 0 else { continue }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
        // Must be an AF_INET socket whose local port is the server port.
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                getsockname(fd, sp, &addrLen) == 0
            }
        }
        guard named, addr.sin_family == sa_family_t(AF_INET) else { continue }
        guard Int(UInt16(bigEndian: addr.sin_port)) == port else { continue }
        // Distinguish the listener from accepted connections (which share the
        // listener's local port): a listening socket has no peer, so
        // getpeername fails with ENOTCONN. SO_ACCEPTCONN is unreadable via
        // getsockopt on macOS (ENOPROTOOPT), so getpeername is the reliable
        // test here. This leaves live client connection fds untouched.
        var peer = sockaddr_in()
        var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let hasPeer = withUnsafeMutablePointer(to: &peer) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                getpeername(fd, sp, &peerLen) == 0
            }
        }
        guard !hasPeer else { continue }
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        patched += 1
    }
    sonataFileLog("HTTP server: set FD_CLOEXEC on \(patched) listen socket(s) for port \(port)")
}

@main
struct SonataApp: App {
    let dbPool: DatabasePool

    // Process-wide handle to the DatabasePool so no-registry callers (e.g.
    // WorkersView) can reach the DB without a passed-in dependency. Set once,
    // immediately after `pool` is initialized in init().
    nonisolated(unsafe) static var sharedDbPool: DatabasePool?

    init() {
        // Tee stdout/stderr into ~/Library/Logs/Sonata.log so every print() and
        // runtime stderr write is captured by the in-app LogsView. Must run
        // before any other code that might print, so it lives at the very top
        // of init().
        installSonataStdoutRedirect()

        // Raise the file-descriptor soft limit before anything opens sockets or
        // spawns workers. macOS gives GUI apps a 256 soft limit; that ceiling
        // is what wedged the HTTP server on 2026-07-17 (EMFILE → NIO tore the
        // server down permanently). 10240 is well above steady-state usage and
        // under the kernel's per-process cap. See raiseFileDescriptorLimit.
        raiseFileDescriptorLimit(to: 10240)

        // Singleton guard, part 1: another *bundled* Sonata is already running.
        // Bring it to front and stand down. This is the double-click case.
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.sona.Sonata"
        )
        if runningApps.count > 1 {
            if let existing = runningApps.first(where: { $0 != NSRunningApplication.current }) {
                existing.activate()
            }
            sonataFileLog("Sonata init: another instance already running, exiting")
            exit(0)
        }

        // Singleton guard, part 2 — the one that actually holds.
        //
        // The check above only sees apps macOS knows as bundles, so a binary run
        // straight from `.build/debug/Sonata` sails past it: an unbundled process
        // has no bundle identifier to match on. That is exactly how a dev build
        // came up alongside the live app on 2026-07-13, republished the fleet's
        // MCP config to its own port, and took the worker channel down with it
        // when it died.
        //
        // The flock on <dataDir>/sonata.lock has no such blind spot — it is a
        // property of the data directory, not of how the process was launched.
        // The instance already holding it keeps running, untouched; the newcomer
        // yields. To run a dev build alongside the app, give it its own data
        // directory (see the message below), which is its own lock.
        if !SonataInstance.acquireLock() {
            let message = """
                Sonata init: another Sonata already owns \(SonataInstance.dataDirectory) — exiting.
                To run an isolated instance alongside it:
                  SONATA_DATA_DIR=/tmp/sonata-dev SONATA_PORT=3299 .build/debug/Sonata
                ($HOME does NOT isolate the data directory — it resolves via getpwuid.)
                """
            sonataFileLog(message)
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(0)
        }

        sonataFileLog("Sonata init: \(SonataInstance.roleDescription)")

        // Make the app appear in dock and app switcher
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        sonataFileLog("Sonata init: starting (port \(sonataPort))")

        do {
            self.dbPool = try DatabaseManager.openDatabase()
        } catch {
            sonataFileLog("Sonata FATAL: database init failed — \(error)")
            fatalError("Sonata: Failed to initialize database — \(error)")
        }

        // Register for app termination to cleanly release the HTTP port.
        // Also tear down internal model servers (pith chat on 7713,
        // embedding on 7712) so they don't survive as orphans across an app
        // quit. Hardcoded internal models are always killed; user-installed
        // models are killed only if we spawned them this run — adopted
        // orphans from a prior run stay running by design.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { _ in
            // The model servers sit on fixed ports (pith 7713, embedding 7712)
            // and terminateOnQuit pkills those ports unconditionally — it cannot
            // tell its own server from another instance's. From a secondary that
            // means a quitting dev binary reaps the PRIMARY's live model servers.
            // A secondary never started them, so it has nothing to clean up.
            guard SonataInstance.isPrimary else {
                sonataFileLog("App terminating — secondary instance, leaving shared model servers alone")
                _exit(0)
            }
            sonataFileLog("App terminating — shutting down internal model servers + releasing port")
            ChatServerManager.terminateOnQuit()
            EmbeddingServerManager.terminateOnQuit()
            _exit(0)
        }

        // Machine-wide user config — only the primary instance may touch it.
        //
        // ~/.claude.json and ~/.claude/mcp.json are how EVERY Claude Code session
        // on this machine finds Sonata. A secondary instance writing them
        // repoints the entire fleet at itself, and the fleet loses its channel
        // the moment that instance exits. This is not hypothetical: it is what
        // happened on 2026-07-13, seconds after a debug binary came up on a
        // spare port. A secondary is a guest — it reads this config, it does not
        // publish it.
        if SonataInstance.isPrimary {
            // Ensure memory + sonata-bridge MCP servers are in global ~/.claude.json
            ensureGlobalMCPServers()

            // Install/refresh the `sona` shell launcher in ~/.zshrc
            ensureSonaLauncher()

            // Deploy bundled Claude Code skills (currently just /afk) to ~/.claude/skills/
            ensureBundledSkills()
        } else {
            sonataFileLog(
                "Sonata init: secondary instance — skipping global config writes "
                + "(~/.claude.json, ~/.claude/mcp.json, ~/.zshrc, ~/.claude/skills)")
        }

        // Role directories live under this instance's data dir, so a secondary
        // creates its own rather than writing the primary's.
        ensureRoleDirectories()

        let pool = self.dbPool
        SonataApp.sharedDbPool = pool
        let port = sonataPort

        // Start the HTTP server + all Phase 3 services in a detached task
        // so it doesn't block the main (SwiftUI) run loop.
        Task.detached {
            do {
                var logger = Logger(label: "sonata.http")
                logger.logLevel = .info
                logger.info("Starting Sonata HTTP server on 127.0.0.1:\(port)")
                sonataFileLog("HTTP task: entered detached task, about to build router")

                // Create scheduler early so routes can reference it
                // MeiliSearch full-text search subsystem.
                //
                // Bound to a fixed port (7711) with its data under the primary's
                // data dir, so a secondary instance starting it would fight the
                // primary for both. A secondary runs without full-text search
                // rather than trampling the running one.
                let meili = MeiliSearchManager()
                if SonataInstance.isPrimary {
                    await meili.start(dbPool: pool)
                    await meili.ensureIndexes()
                } else {
                    sonataFileLog("Sonata init: secondary instance — skipping MeiliSearch (shared port 7711)")
                }

                // Conversation-log search (Meili `emails` + `sessions`) — the
                // subsystem's original purpose, restored 2026-06-12. First
                // transcript pass over ~/.claude/projects runs in the
                // background and resumes across launches via
                // transcriptIndexState.
                let conversationIndexer = ConversationIndexer(
                    dbPool: pool, search: meili,
                    logger: Logger(label: "sonata.conversation.indexer"))
                await conversationIndexer.start()

                let scheduler = SchedulerActor(dbPool: pool)

                let router = Router(context: BasicWebSocketRequestContext.self)

                // Unified action registry — every HTTP endpoint and MCP tool
                // comes from a single definition. See Sources/Actions/*.swift.
                let registry = ActionRegistry()
                registry.scheduler = scheduler
                registry.search = meili
                registry.register(memoryActions)
                registry.register(recallActions)
                registry.register(sessionHistoryActions)
                registry.register(entityActions)
                registry.register(relationActions)
                registry.register(taskActions)
                registry.register(taskWatcherActions)
                registry.register(workerActions)
                registry.register(workerEventActions)
                registry.register(sidecarHintActions)
                registry.register(workerToolDenialActions)
                registry.register(inspectorAction)
                registry.register(globalAFKActions)
                registry.register(dmActions)
                registry.register(calendarActions)
                registry.register(emailActions)
                registry.register(emailOutboundActions)
                registry.register(emailInboxActions)
                registry.register(schedulerActions)
                registry.register(supervisorActions)
                registry.register(supervisorConfigActions)
                registry.register(webviewSessionConfigActions)
                registry.register(wikiActions)
                registry.register(coreBlockActions)
                registry.register(checkpointActions)
                registry.register(secretActions)
                registry.register(documentActions)
                registry.register(embeddingActions)
                registry.register(contactActions)
                registry.register(fileActions)
                registry.register(systemActions)
                registry.register(pithActions)
                registry.register(statsActions)
                registry.register(compositeActions)
                registry.register(whatHappenedActions)
                registerInternalWhatHappenedDomains(dbPool: pool)

                // No registry to publish. MCPConnections.shared and MCPAuth.shared are
                // process-init singletons — no explicit wiring needed. Callers that used
                // to consult the old registry now query the DB directly.
                //
                // NOTE: MCPHTTPRouter.register no longer takes a `registry` argument —
                // state comes from MCPConnections.shared + MCPAuth.shared inside the router.
                _ = MCPAuth.shared
                _ = MCPConnections.shared

                // Create PluginManager (before mountHTTP so plugin management routes are included)
                let pluginManager = PluginManager(dbPool: pool, registry: registry)

                // Register plugin management actions BEFORE mountHTTP
                registry.register(makePluginActions(pluginManager: pluginManager))

                registry.mountHTTP(on: router, dbPool: pool)
                registry.mountMetaRoutes(on: router, dbPool: pool)

                // NOTE (2026-07-16): The WebSocket MCP handler at ws://.../mcp
                // — served by SonataMCPHandler in Sources/MCP/SonataMCPServer.swift
                // — was removed here. That handler was the FIRST MCP surface
                // (predating this file's MCPServer/ implementation) and was left
                // in place when the HTTP+SSE server became canonical. Nothing
                // wires to it any more: no `.mcp.json` uses the ws:// URL, no
                // per-session config Sonata writes references it, and the
                // dashboard bundle has zero refs. Keeping it meant two
                // divergent tools/call handlers (the WS one lacked the
                // empty-args server note and used the old omit-on-success
                // isError shape), which is exactly the "one refactor updates
                // half, the other rots" pattern we spent today closing out.
                // If a WS transport is needed again, forward to
                // MCPHandshake.handle rather than re-adding a parallel path.

                // In-app MCP HTTP+SSE server — replaces sonata-bridge.ts.
                // Registry was constructed and published to .shared above,
                // before PluginManager / mountHTTP, to win the race with
                // ContentView.onAppear-driven session spawns. Here we wire it
                // into the HTTP router, notification dispatcher, and sweepers.
                MCPHTTPRouter.register(
                    on: router,
                    actionRegistry: registry,
                    dbPool: pool,
                    logger: logger
                )
                // MCPNotificationDispatcher.bind(registry:) deleted — the dispatcher
                // uses MCPConnections.shared directly, no binding needed.
                let mcpSweeper = MCPSessionSweeper(
                    dbPool: pool,
                    logger: logger
                )
                await mcpSweeper.start()
                let webviewSweeper = WebviewSessionSweeper(
                    dbPool: pool, logger: Logger(label: "sonata.webview.sweeper"))
                await webviewSweeper.start()
                // Embeds any memory row missing its vector (backlog drain on
                // boot, then a 60s safety net behind mem_store's embed-on-insert).
                let embeddingSweeper = EmbeddingSweeper(
                    dbPool: pool, logger: Logger(label: "sonata.embedding.sweeper"))
                await embeddingSweeper.start()
                let mcpEventPusher = MCPEventPusher(dbPool: pool, logger: logger)
                await mcpEventPusher.start()
                logger.info("MCP HTTP endpoint registered at http://127.0.0.1:\(port)/mcp/{sessionKey} (flag SONATA_MCP_INPROC gates coordinator-side cutover)")

                // Prime the SelfInstanceIdCache in the background so the first
                // dm_send doesn't pay the sonar-card fetch cost. Best-effort, no
                // wait. Non-empty sentinel is REQUIRED — isSelf("") short-circuits
                // without touching the cache.
                Task.detached { _ = await SonarPeerLookup.isSelf("__warm_cache_sentinel__") }

                // Dispatcher singleton retired (2026-05-18). External
                // launchers identify themselves via bearer = sessionKey
                // (set by SONA_SESSION_ID env var via the sona alias).
                // See ~/.sonata/wiki/sonata/mcp-identity.md.

                // Serve web dashboard files (HTML/CSS/JS)
                let webPaths = [
                    "\(NSHomeDirectory())/memory/Sonata/Sources/Sonata/Resources/web",
                    Bundle.main.resourcePath.map { "\($0)/web" },
                    Bundle.main.resourcePath.map { "\($0)/Resources/web" },
                ].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }

                if let webDir = webPaths {
                    router.get("/web/{path}") { request, context -> Response in
                        let path = context.parameters.get("path") ?? ""
                        let filePath = "\(webDir)/\(path)"
                        guard FileManager.default.fileExists(atPath: filePath),
                              let data = FileManager.default.contents(atPath: filePath) else {
                            return Response(status: .notFound)
                        }
                        let ext = (path as NSString).pathExtension
                        let contentType: String
                        switch ext {
                        case "html": contentType = "text/html; charset=utf-8"
                        case "css": contentType = "text/css; charset=utf-8"
                        case "js": contentType = "application/javascript; charset=utf-8"
                        default: contentType = "application/octet-stream"
                        }
                        var headers = HTTPFields()
                        headers[.contentType] = contentType
                        return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(data: data)))
                    }
                    logger.info("Web dashboard: serving from \(webDir)")
                } else {
                    logger.warning("Web dashboard: no web resource directory found")
                }

                // Wait for port to be free (previous instance may still be releasing)
                await waitForPortFree(port)

                // WebSocket upgrade removed with the SonataMCPHandler cleanup
                // above (2026-07-16). Plain HTTP1 now — nothing this server
                // exposes uses WS. If it comes back, use
                // `.http1WebSocketUpgrade(webSocketRouter:)` with a real ws
                // router again.
                // Supervised HTTP server (2026-07-17 fd-exhaustion wedge).
                //
                // A transient fcntl/EMFILE spike makes NIO's ServiceGroup treat
                // the HTTP server as finished-unexpectedly and tear it down for
                // good — the process keeps running (scheduler, workers, health
                // monitor) but the server never comes back, so every request
                // times out. Instead of a one-shot `app.runService()`, rebuild
                // and rerun the Application on any unexpected exit. The restart
                // budget resets after a healthy run, so a one-off spike
                // self-heals while a hard-broken config still gives up rather
                // than hot-looping forever.
                //
                // runService() only returns/throws on teardown. Real process
                // termination _exit()s from the willTerminate observer before we
                // reach here, so a return we actually observe is the failure
                // case → restart (unless our own task was cancelled).
                let serverTask = Task { [logger] in
                    let maxRestarts = 8
                    let healthyRunSeconds: TimeInterval = 60
                    var attempt = 0
                    while !Task.isCancelled {
                        let startedAt = Date()
                        // After each (re)bind, strip the acceptor socket from
                        // child-process inheritance so a later teardown can't
                        // leave the port pinned in LISTEN (fd hygiene, fix #3).
                        let cloexecSweep = Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            setCloseOnExecOnListenSockets(port: port)
                        }
                        do {
                            // Race the server against an active /api/ping probe.
                            // Whichever finishes first ends the group: normally
                            // that is the watchdog throwing `livenessLost`, which
                            // cancels `runService()` and drops us into the restart
                            // path below. A server that dies the SwiftNIO way
                            // still works exactly as it did before.
                            try await withThrowingTaskGroup(of: Void.self) { group in
                                group.addTask {
                                    let app = Application(
                                        router: router,
                                        server: .http1(),
                                        configuration: .init(address: .hostname("127.0.0.1", port: port)),
                                        logger: logger
                                    )
                                    try await app.runService()
                                }
                                group.addTask {
                                    try await httpLivenessWatchdog(port: port)
                                }
                                try await group.next()
                                group.cancelAll()
                            }
                            cloexecSweep.cancel()
                            if Task.isCancelled { break }
                            sonataFileLog("HTTP server: runService returned unexpectedly — restarting")
                        } catch is CancellationError {
                            cloexecSweep.cancel()
                            break
                        } catch {
                            cloexecSweep.cancel()
                            if Task.isCancelled { break }
                            sonataFileLog("HTTP server: runService threw — \(error) — restarting")
                        }
                        // A server that stayed up long enough counts as healthy;
                        // reset the budget so lifetime spikes don't accumulate.
                        if Date().timeIntervalSince(startedAt) >= healthyRunSeconds { attempt = 0 }
                        attempt += 1
                        if attempt > maxRestarts {
                            sonataFileLog("HTTP FATAL: HTTP server exceeded \(maxRestarts) restarts — giving up")
                            throw HTTPServerSupervisorError.restartBudgetExhausted(maxRestarts)
                        }
                        let backoff = min(Double(attempt), 5.0)
                        try? await Task.sleep(for: .seconds(backoff))
                        // The outgoing listener may still be tearing down; give
                        // it a moment rather than burning a restart on EADDRINUSE.
                        await waitForPortFree(port)
                        sonataFileLog("HTTP server: restart attempt \(attempt)/\(maxRestarts)")
                    }
                }

                // Give the HTTP server a moment to bind before starting services
                try? await Task.sleep(for: .milliseconds(500))
                sonataFileLog("HTTP server: binding complete, starting services")

                // Start all enabled plugins — blocks until all are running or failed.
                // Must complete before workers spawn so plugin MCP tools are available.
                //
                // Plugin daemons bind fixed ports (sonar on 4000, …) and Sonata
                // kills whatever already holds those ports before spawning its
                // own. From a secondary instance that means killing the primary's
                // live daemons and adopting them — how the sonar bridge died on
                // 2026-07-13. A secondary runs pluginless.
                if SonataInstance.isPrimary {
                    await pluginManager.startEnabledPlugins()
                    sonataFileLog("Plugin system: initialization complete")
                } else {
                    sonataFileLog("Sonata init: secondary instance — skipping plugin daemons (shared fixed ports)")
                }

                // --- Phase 3: Initialize all scheduler services ---

                // 1. Scheduler Actor (created earlier, before routes)
                // Register internal functions before start so any due calendar
                // events of taskType=internal can fire immediately.
                await scheduler.registerInternal("wiki-compilation") { [pool] in
                    try await WikiCompilationJob.run(dbPool: pool)
                }
                await scheduler.start()
                _ = await scheduler.status()

                // Count calendar events and cron jobs from DB for the startup log
                let calendarCount: Int = (try? await pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendarEvents WHERE enabled = 1") ?? 0
                }) ?? 0
                let cronCount: Int = (try? await pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduledJobs WHERE enabled = 1") ?? 0
                }) ?? 0

                // 2. Email Handler
                let emailHandler = EmailHandler(dbPool: pool)
                await emailHandler.start()
                // Late-bind into the action registry so approval actions
                // (contact_set_email_flags) can re-dispatch quarantined mail.
                // Routes were registered before this point, so this is set here
                // rather than alongside registry.scheduler at boot.
                registry.emailHandler = emailHandler

                // 3. Friend Relay
                let friendRelay = FriendRelay(dbPool: pool)
                await friendRelay.start()

                // 4. Task Dispatcher (dispatches pending tasks to bridge workers)
                let dispatcher = TaskDispatcher(dbPool: pool)
                await dispatcher.start()

                // 5. Health Monitor (with scheduler status closure)
                let healthMonitor = HealthMonitor(
                    dbPool: pool,
                    port: port,
                    schedulerStatus: { await scheduler.status().count >= 0 },  // returns true if scheduler is reachable
                    // Backstop pool-size check (2026-05-18 incident, Fix 4).
                    // Returns target=defaultWorkerCount and effective=count of
                    // workers in a non-.offline status. Read on MainActor since
                    // WorkerManager.workers is @MainActor isolated.
                    workerPoolStatus: {
                        await MainActor.run {
                            let target = WorkerManager.defaultWorkerCount
                            let effective = WorkerManager.shared.workers.filter { $0.status != .offline }.count
                            return (target: target, effective: effective)
                        }
                    },
                    // Hand overdue-task worker IDs to the pool for a full
                    // drain+SIGTERM+respawn (reapOverdueTasks → cycleWorkerById).
                    // Read on MainActor since WorkerManager.workers + cycleWorker
                    // are @MainActor-adjacent. Skips workers already gone or
                    // mid-transition.
                    cycleStuckWorkers: { workerIds in
                        await MainActor.run {
                            for wid in workerIds {
                                WorkerManager.shared.cycleWorkerById(wid)
                            }
                        }
                    },
                    // Enables the periodic search-index + embedding-coverage
                    // reconcile (self-heals docs drift, alarms on any index or
                    // vector gap) — the standing guard against silent drift.
                    search: meili
                )
                await healthMonitor.start()

                // 7. Backup Manager (nightly SQLite backup + S3)
                let backupManager = BackupManager(dbPool: pool)
                await backupManager.start()

                // 8. Wiki File Watcher (FSEvents on ~/.sonata/wiki/ and ~/.sonata/private/)
                let wikiWatcher = WikiFileWatcher(dbPool: pool, search: meili)
                await wikiWatcher.start()

                // 8a. MeiliSearch initial backfill (first run or after data clear)
                Task {
                    await meili.backfillWiki(dbPool: pool)
                    await meili.backfillArchive(dbPool: pool)
                    await meili.backfillDocs()
                    await meili.backfillPrivate()
                }

                // 8b. Pith L0/L1 backfill for memories created before pith-on-insert
                // landed. Long-running (one chat-server roundtrip per memory) so it
                // runs in a detached Task that doesn't block boot. First call lazily
                // starts the chat server (downloading the 4.6 GB GGUF on absolute
                // first run). Idempotent: resumes from where prior runs left off.
                Task {
                    await PithBackfill.shared.run(dbPool: pool)
                }

                // 8c. Hydrate the user-installed local chat model registry from
                // the v22 `installedChatModels` table so worker/session pickers
                // see them (Phase F.3). Sync — small, must complete before the
                // worker/session UI hits the picker on first paint.
                await InstalledChatModelManager.shared.bootstrap(dbPool: pool)

                // 8d. Boot the Anthropic model catalog (v25). Extracts model IDs
                // from the user's installed `claude` binary so the picker menu
                // matches whatever Claude Code will actually accept via --model.
                // Mtime-cached, so repeat launches without a CLI update are free.
                await AnthropicModelStore.shared.bootstrap(
                    dbPool: pool,
                    binaryPath: InteractiveSessionTab.claudeBinary
                )

                logger.info("Sonata scheduler started: \(calendarCount) calendar events, \(cronCount) cron jobs, email polling every 2m, nightly backups enabled, wiki file watcher active")

                // 6a. Reap ghost worker processes left over from any prior Sonata
                // run. `pgrep -f mcp-cfg/worker-*.json` enumerates every claude
                // worker on the host; anything without a matching workers row
                // gets SIGTERM/SIGKILL. Runs BEFORE spawnDefaultWorkers so a
                // fresh pool doesn't compete for the same slot indices with
                // ghosts still holding MCP SSE streams. See GhostWorkerReaper.
                _ = await GhostWorkerReaper.reap(dbPool: pool, logger: logger, source: "boot")

                // 6a-cont. Periodic ghost reaper. The boot reap only catches
                // ghosts left over from a prior run; new ghosts can appear
                // during normal operation when a worker's parent process
                // dies but its MCP subprocess survives (see memory
                // 8146b6c7 — 2026-07-12 Scout eyebrowse orphan). AE II
                // reported ghost workers on evan-mac at 2h+ uptime on
                // 2026-07-13; the ghosts survived because reap() only
                // ran at boot. Runs every 5 minutes with source="periodic".
                Task.detached(priority: .background) {
                    let interval: UInt64 = 5 * 60 * 1_000_000_000
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: interval)
                        _ = await GhostWorkerReaper.reap(
                            dbPool: pool, logger: logger, source: "periodic"
                        )
                        // Offline-resurrect: replace pool workers that have
                        // been offline for >= 90 min with no active event
                        // AND no live process. The escalation ladder
                        // correctly declines to reap offline workers when
                        // there's nothing to reassign, but that leaves the
                        // slot dead — no maintainPoolSize refill fires
                        // for slots beyond defaultWorkerCount (e.g. a user
                        // clicked "Add" to expand to sona-worker-5 and
                        // that worker later died). sona-worker-5 case,
                        // 2026-07-15: stale offline row sat 4.8 days before
                        // startup worker_purge cleared it. 90 min >> any
                        // legitimate transient offline (MCP reconnect ~s,
                        // escalation grace 5m), so a row still offline at
                        // that mark is dead. Live-process pgrep is a
                        // second guard against false positives.
                        await resurrectAbandonedPoolSlots(dbPool: pool, logger: logger)
                    }
                }

                // 6. Respawn recovery workers (sonata-restart-recovery-v0 §4) then top up
                // the default pool. Both run on MainActor since they create terminal views.
                let workerCount = WorkerManager.defaultWorkerCount
                // sonata-restart-recovery v0 (claude/documents/plans/sonata-restart-recovery-v0-plan.md):
                // when toggled on, respawn workers that died holding active work, reusing
                // their prior workerId/sessionId so claude --resume loads the prior JSONL.
                // Toggle stored in UserDefaults at "restartRecoveryEnabled" (UI exposes it);
                // SONATA_RESTART_RECOVERY env override available for testing.
                let enableRecovery = WorkerManager.restartRecoveryEnabled
                let recovered = enableRecovery
                    ? await WorkerManager.shared.respawnRecoveryWorkers(dbPool: pool)
                    : 0
                await MainActor.run {
                    WorkerManager.shared.spawnDefaultWorkers(reservingFor: recovered)
                    WorkerManager.shared.startHealthPolling()
                }
                logger.info("Spawned \(workerCount) default workers (\(recovered) recovered, recovery=\(enableRecovery ? "on" : "off"))")

                // 6b. Spawn the supervisor window (hidden by default — accessible from Window menu).
                // Creating the NSWindow spins up the SupervisorTerminalView, which starts Claude
                // with the supervisor prompt and role. Window close hides instead of destroying.
                await MainActor.run {
                    SupervisorWindowController.shared.ensureStarted()
                }
                logger.info("Supervisor window created (hidden)")

                // 6c. Auto-start restored interactive sessions (sona/terminal
                // tabs) from the launch Task so each reconnects its Claude
                // process + MCP/SSE stream on launch — exactly like workers and
                // the supervisor — instead of staying suspended until the user
                // focuses the tab. Window-independent: runs even if the main
                // WindowGroup window never comes to the foreground (e.g. a
                // headless relaunch by the deploy agent), the case where
                // ContentView.onAppear never fires and no session ever connects.
                // bootstrap() is idempotent, so ContentView.onAppear's later
                // call is a harmless no-op.
                await MainActor.run {
                    _ = InteractiveSessionsViewModel.shared.bootstrap(dbPool: pool)
                    GlobalAFKController.shared.bootstrap(dbPool: pool)
                }
                await GlobalAFKOrchestrator.shared.start(dbPool: pool)
                logger.info("Auto-started restored interactive sessions")

                // 6d. Bring up registered sidecars — long-lived Claude Code
                // sessions that receive events by type and dispatch each to a
                // headless internal agent. Runs after the worker pool and the
                // supervisor because a sidecar registers a `workers` row of its
                // own and we want the pool's slots claimed first.
                await bootSidecars(dbPool: pool, logger: logger)

                // Register shutdown handler
                let shutdownHandler = {
                    logger.info("Sonata shutting down — stopping all services")
                    // Cancel the supervisor first so runService() unwinds
                    // gracefully and the restart loop sees isCancelled → exits
                    // instead of rebinding the port during shutdown.
                    serverTask.cancel()
                    await scheduler.shutdown()
                    await emailHandler.shutdown()
                    await friendRelay.shutdown()
                    await healthMonitor.shutdown()
                    await backupManager.shutdown()
                    await wikiWatcher.shutdown()
                    await pluginManager.shutdown()
                    await meili.shutdown()
                    logger.info("Sonata shutdown complete")
                }

                // Listen for termination signals to shut down gracefully
                let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM)
                signal(SIGTERM, SIG_IGN)
                sigTermSource.setEventHandler {
                    Task { await shutdownHandler() }
                }
                sigTermSource.resume()

                let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT)
                signal(SIGINT, SIG_IGN)
                sigIntSource.setEventHandler {
                    Task { await shutdownHandler() }
                }
                sigIntSource.resume()

                // Await the supervisor — this blocks until the server stops for
                // good (graceful shutdown or exhausted restart budget). The
                // supervising task rethrows only when the restart budget is
                // exhausted; that surfaces here as a fatal-server log below.
                try await serverTask.value
            } catch {
                // Log to both Logger and file so we can see what went wrong
                let logger = Logger(label: "sonata.http")
                logger.error("HTTP server failed: \(error)")
                sonataFileLog("HTTP FATAL: server failed — \(error)")
            }
        }
    }

    @FocusedValue(\.selectedTab) var selectedTab
    @FocusedValue(\.focusSearchBar) var focusSearchBar

    // Whole-window translucency, controlled by the General-settings slider.
    // Default 1.0 (fully opaque); clamped to 0.3…1.0 where applied.
    @AppStorage(WindowOpacitySetting.key) private var windowOpacity: Double = WindowOpacitySetting.defaultValue

    // MARK: - Studio: DBPool environment plumbing (per impl-spec §10 Diff E)
    //
    // Studio's tab-scoped StudioStore needs the DatabasePool via SwiftUI's
    // environment (plan §11 D2 — no singleton). The environment key + value
    // accessor live alongside the app entrypoint so the value is injected
    // once at the WindowGroup boundary below.

    var body: some Scene {
        WindowGroup("") {
            StartupGate(dbPool: dbPool, port: sonataPort) {
                ContentView()
                    .frame(minWidth: 1100, minHeight: 720)
                    .environment(\.dbPool, dbPool)
                    .warmWindowTitlebar()
                    .windowOpacity(windowOpacity)
                    // s4a:// URL scheme handler. The Info.plist registers the
                    // scheme with macOS LaunchServices; .onOpenURL is what
                    // SwiftUI hands the resulting URL through. Boot-time pending
                    // URLs (Sonata wasn't running when the user clicked the
                    // link) replay through here automatically after launch
                    // finishes — no manual queueing needed.
                    .onOpenURL { url in
                        if StudioDeepLinkRouter.isInviteURL(url) {
                            StudioDeepLinkRouter.shared.handle(url: url)
                        }
                    }
            }
            // Lock Sonata to dark appearance regardless of the user's macOS
            // setting (Spotify / Discord / Linear pattern). The loader, theme
            // tokens, and warm chrome are designed for dark; light mode would
            // wash them out.
            .preferredColorScheme(.dark)
            // Override the system accent so List selections, toggles, focus
            // rings, etc. render in Sonata's ember tone instead of macOS
            // default blue. Without this, the Workers sidebar selection (and
            // anything else relying on Color.accentColor) takes on the user's
            // System Settings → Appearance → Accent Color, which collides
            // with the warm chrome on both Sequoia 15.3 and 15.7+ point
            // releases. See Theme.Color.selectionAccent (an ember orange).
            .tint(Theme.Color.selectionAccent)
        }
        // Default window size on first launch (and a fallback when SwiftUI's
        // window state restoration fails — currently a regression caused by
        // our AppKit titlebar interop, TODO investigate). Picked to be roomy
        // on a 13" MBP without overflowing.
        .defaultSize(WindowFramePersistence.initialSize)
        .commands {
            // Tab navigation: Cmd+1 through Cmd+9, Cmd+0
            CommandGroup(after: .toolbar) {
                Section {
                    Button("Search Sona…") { focusSearchBar?() }
                        .keyboardShortcut("k", modifiers: .command)
                }
                Section {
                    Button("Workers") { selectedTab?.wrappedValue = .workers }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Memory") { selectedTab?.wrappedValue = .memory }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("Tasks") { selectedTab?.wrappedValue = .tasks }
                        .keyboardShortcut("3", modifiers: .command)
                    Button("Schedule") { selectedTab?.wrappedValue = .schedule }
                        .keyboardShortcut("4", modifiers: .command)
                    Button("Email") { selectedTab?.wrappedValue = .email }
                        .keyboardShortcut("5", modifiers: .command)
                    Button("People") { selectedTab?.wrappedValue = .people }
                        .keyboardShortcut("6", modifiers: .command)
                    Button("Wiki") { selectedTab?.wrappedValue = .wiki }
                        .keyboardShortcut("7", modifiers: .command)
                    Button("Files") { selectedTab?.wrappedValue = .files }
                        .keyboardShortcut("8", modifiers: .command)
                    Button("Dashboard") { selectedTab?.wrappedValue = .dashboard }
                        .keyboardShortcut("9", modifiers: .command)
                    Button("Settings") { selectedTab?.wrappedValue = .settings }
                        .keyboardShortcut("0", modifiers: .command)
                    Button("Plugins") { selectedTab?.wrappedValue = .plugins }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("Studio") { selectedTab?.wrappedValue = .studio }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }

            CommandGroup(after: .importExport) {
                Button("Export Sonata Data...") {
                    exportSonataData()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Import Sonata Data...") {
                    importSonataData()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandGroup(after: .windowArrangement) {
                Button("Supervisor") {
                    SupervisorWindowController.shared.show()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                // "Interactive Sessions" menu item retired — the in-rail
                // "Sessions" tab owns this experience now. Use ⌘1-9 or
                // click the rail's Sessions icon.

                Menu("Sidecars") {
                    SidecarsMenuContent()
                }

                Button("Logs") {
                    LogsWindowController.shared.show()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }

    // MARK: - Export

    private func exportSonataData() {
        let panel = NSSavePanel()
        panel.title = "Export Sonata Data"
        panel.nameFieldStringValue = "sonata-backup-\(dateStamp()).sonata-backup"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task.detached {
            let sonataDir = URL(fileURLWithPath: SonataInstance.dataDirectory)
            let tempZip = FileManager.default.temporaryDirectory
                .appendingPathComponent("sonata-export-\(UUID().uuidString).zip")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-r", tempZip.path, "."]
            process.currentDirectoryURL = sonataDir

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    try FileManager.default.moveItem(at: tempZip, to: url)
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Export Complete"
                        alert.informativeText = "Sonata data exported to:\n\(url.lastPathComponent)"
                        alert.alertStyle = .informational
                        alert.runModal()
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Import

    private func importSonataData() {
        let panel = NSOpenPanel()
        panel.title = "Import Sonata Data"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a .sonata-backup file to restore"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Confirm before overwriting
        let confirm = NSAlert()
        confirm.messageText = "Restore Sonata Data?"
        confirm.informativeText = "This will replace all data in ~/.sonata/ with the contents of the backup. This cannot be undone."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Restore")
        confirm.addButton(withTitle: "Cancel")

        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        Task.detached {
            let sonataDir = URL(fileURLWithPath: SonataInstance.dataDirectory)

            do {
                // Clear existing data
                if FileManager.default.fileExists(atPath: sonataDir.path) {
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: sonataDir, includingPropertiesForKeys: nil)
                    for item in contents {
                        try FileManager.default.removeItem(at: item)
                    }
                }

                // Unzip backup
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", url.path, "-d", sonataDir.path]

                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Import Complete"
                        alert.informativeText = "Sonata data restored. Restart the app to load the new data."
                        alert.alertStyle = .informational
                        alert.runModal()
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Import Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// MARK: - Supervisor Window

/// Manages the persistent supervisor NSWindow. Created hidden at startup so the
/// underlying Claude process keeps running even when the user has never opened
/// the window. Close events hide the window instead of destroying it.
@MainActor
final class SupervisorWindowController: NSObject, NSWindowDelegate {
    static let shared = SupervisorWindowController()

    private var window: NSWindow?

    /// Create the window (and start the underlying process) if it doesn't exist yet.
    /// The window is created hidden — the user must explicitly open it.
    private var coordinator: SupervisorCoordinator?

    func ensureStarted() {
        guard window == nil else { return }

        // Create terminal view directly (same pattern as Worker)
        let termView = DropEnabledTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        termView.applyWarmChrome()
        termView.enableWarmTerminalColors()  // same themed text/palette as sessions
        let coord = SupervisorCoordinator(terminalView: termView)
        self.coordinator = coord
        termView.processDelegate = coord

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Supervisor"
        win.contentView = termView
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        self.window = win

        // Start the process after a brief delay for the view to lay out
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            coord.startProcess()
        }
    }

    func show() {
        ensureStarted()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        DispatchQueue.main.async {
            sender.orderOut(nil)
        }
        return false
    }
}
