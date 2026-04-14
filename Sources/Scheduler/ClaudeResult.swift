import Foundation

/// Result of a Claude CLI session spawned by `ClaudeProcessManager`.
struct ClaudeResult: Sendable {
    /// Number of conversation turns completed.
    let numTurns: Int
    /// Estimated total cost in USD (from Claude's cost_usd field).
    let totalCost: Double
    /// Wall-clock duration of the session in milliseconds.
    let durationMs: Int
    /// Peak context utilization percentage observed during the session.
    let peakContext: Double
    /// Whether the session ended with an error.
    let isError: Bool
    /// Human-readable error message, if any.
    let errorMessage: String?
    /// The Claude session ID (from the first `system` message).
    let sessionId: String?

    /// Convenience: did the session complete successfully?
    var isSuccess: Bool { !isError }
}
