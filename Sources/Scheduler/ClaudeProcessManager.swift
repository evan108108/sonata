import Foundation

/// Spawns and manages `claude -p` processes, replacing `daemon/claude-sdk.js`.
///
/// Uses `--output-format stream-json` to parse structured messages from stdout,
/// tracking turn count, token usage, cost, and session ID.
enum ClaudeProcessManager {

    // MARK: - Configuration

    /// Path to the Claude CLI binary.
    static var binaryPath: String = {
        // Check common locations
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            ProcessInfo.processInfo.environment["CLAUDE_BINARY"] ?? ""
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/opt/homebrew/bin/claude"
    }()

    /// Default timeout for sessions (10 minutes).
    static let defaultTimeoutMs: Int = 600_000

    /// Log file path.
    private static let logPath: String = {
        let dir = NSHomeDirectory() + "/.sonata/logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/claude-sessions.log"
    }()

    // MARK: - Public API

    /// Run a Claude CLI session and return the result.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to send to Claude.
    ///   - model: Model name (e.g. "claude-sonnet-4-20250514"). Nil uses Claude's default.
    ///   - maxTurns: Maximum conversation turns.
    ///   - label: Human-readable label for logging.
    ///   - cwd: Working directory for the process.
    ///   - timeoutMs: Timeout in milliseconds.
    ///   - sessionId: Optional session ID to resume.
    /// - Returns: A `ClaudeResult` with session metrics.
    static func run(
        prompt: String,
        model: String? = nil,
        maxTurns: Int = 15,
        label: String = "sonata",
        cwd: String = "/Users/evan/memory",
        timeoutMs: Int? = nil,
        sessionId: String? = nil
    ) async throws -> ClaudeResult {
        let timeout = timeoutMs ?? defaultTimeoutMs
        let startTime = ContinuousClock.now

        // Build arguments
        var args: [String] = [
            "-p", prompt,
            "--max-turns", String(maxTurns),
            "--output-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
        ]

        if let model {
            args += ["--model", model]
        }

        if let sessionId {
            args += ["--session-id", sessionId]
        }

        // Configure process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        // Environment: inherit current, strip CLAUDECODE, set SONA_WORKER
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["SONA_WORKER"] = "1"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // State tracking
        let state = SessionState()

        // Start process
        log("[\(label)] Starting session: model=\(model ?? "default"), maxTurns=\(maxTurns), timeout=\(timeout)ms")

        do {
            try process.run()
        } catch {
            log("[\(label)] Failed to launch process: \(error)")
            return ClaudeResult(
                numTurns: 0, totalCost: 0, durationMs: 0, peakContext: 0,
                isError: true, errorMessage: "Failed to launch claude: \(error.localizedDescription)",
                sessionId: nil
            )
        }

        // Stream stdout and parse JSON messages
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // Collect stderr in background
        let stderrTask = Task<String, Never> {
            let data = stderrHandle.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        // Parse stdout stream-json messages
        let parseTask = Task {
            await parseStreamJSON(handle: stdoutHandle, state: state)
        }

        // Timeout watchdog
        let timeoutTask = Task {
            try await Task.sleep(for: .milliseconds(timeout))
            if process.isRunning {
                log("[\(label)] Timeout after \(timeout)ms — terminating")
                process.terminate()
            }
        }

        // Wait for process to exit
        process.waitUntilExit()
        timeoutTask.cancel()
        await parseTask.value
        let stderrOutput = await stderrTask.value

        let elapsed = startTime.duration(to: .now)
        let durationMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)

        let exitCode = process.terminationStatus
        let isError = exitCode != 0

        let errorMessage: String? = if isError {
            "Exit code \(exitCode)" + (stderrOutput.isEmpty ? "" : ": \(stderrOutput.prefix(500))")
        } else {
            nil
        }

        let result = ClaudeResult(
            numTurns: state.numTurns,
            totalCost: state.totalCost,
            durationMs: durationMs,
            peakContext: state.peakContext,
            isError: isError,
            errorMessage: errorMessage,
            sessionId: state.sessionId
        )

        log("[\(label)] Session complete: turns=\(result.numTurns), cost=$\(String(format: "%.4f", result.totalCost)), duration=\(durationMs)ms, error=\(isError)")

        return result
    }

    // MARK: - Stream JSON Parser

    /// Mutable state accumulated while parsing the stream-json output.
    private final class SessionState: @unchecked Sendable {
        var sessionId: String?
        var numTurns: Int = 0
        var totalCost: Double = 0
        var peakContext: Double = 0

        // Token tracking for context estimation
        var totalInputTokens: Int = 0
        var totalOutputTokens: Int = 0
        let contextWindowSize: Int = 200_000
    }

    /// Parse newline-delimited JSON messages from Claude's stream-json output.
    private static func parseStreamJSON(handle: FileHandle, state: SessionState) async {
        // Read all data and split into lines — stream-json emits one JSON object per line
        var buffer = Data()

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }

        guard let text = String(data: buffer, encoding: .utf8) else { return }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let msgType = json["type"] as? String ?? ""

            switch msgType {
            case "system":
                // Extract session ID
                if let sid = json["session_id"] as? String {
                    state.sessionId = sid
                }

            case "assistant":
                // Each assistant message = one turn
                state.numTurns += 1

            case "result":
                // Final result message contains cost and session ID
                if let costUsd = json["total_cost_usd"] as? Double {
                    state.totalCost = costUsd
                }
                if let sid = json["session_id"] as? String {
                    state.sessionId = sid
                }
                if let numTurns = json["num_turns"] as? Int {
                    state.numTurns = numTurns
                }

            default:
                break
            }

            // Track token usage — check both top-level and nested in message
            let usage: [String: Any]? =
                json["usage"] as? [String: Any]
                ?? (json["message"] as? [String: Any])?["usage"] as? [String: Any]

            if let usage {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0

                state.totalInputTokens = input + cacheRead + cacheCreate
                state.totalOutputTokens = output

                let totalTokens = state.totalInputTokens + state.totalOutputTokens
                let utilization = Double(totalTokens) / Double(state.contextWindowSize) * 100.0
                if utilization > state.peakContext {
                    state.peakContext = utilization
                }
            }
        }
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}
