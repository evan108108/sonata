#!/usr/bin/env node
/**
 * PreToolUse Hook — Session-Local Scheduler Guardrail
 *
 * Blocks session-local scheduling tools (harness's `CronCreate`, and
 * `ScheduleWakeup` at the max-delay clamp) in favour of Sonata's durable
 * scheduler — so a next-morning verification check that the user is
 * counting on to fire while they sleep does not silently die when the
 * calling session exits.
 *
 * Design spec: peer feature request from AE IV via session-b929598e8f5641b4
 * on 2026-08-14, filed after a real miss — a next-morning scout #537
 * verification check was scheduled with the harness's session-local
 * CronCreate; would have died overnight when the session ended. Rescued
 * by migrating to calendar_create manually. Nothing at the decision point
 * surfaced the durable option; the point of this hook is that it can't
 * be forgotten at exactly the moment it matters.
 *
 * Follows the same block-with-override shape as pre-tool-use-agent-
 * guardrail.js (bundled 2026-08-10, ADA-472), because a silent stderr
 * nudge on exit-0 is invisible to the model — only a block reason
 * reaches the model's context.
 *
 * ---------------------------------------------------------------------------
 * ESCAPE HATCHES
 *
 *   CLAUDE_ALLOW_SESSION_SCHEDULE=1
 *     Set on the calling process to bypass this hook for that session
 *     entirely. Every bypass logs a stderr line so an opt-out is visible.
 *     Use when session-local scheduling is genuinely correct for the
 *     duration of a whole session (a long-lived poll that MUST die when
 *     the session dies).
 *
 *   [sonata-scheduler-approved: <one-line reason>] prefix in the tool's
 *   `reason`, `description`, or `prompt` field (whichever the tool uses)
 *     Per-call override. The block reason names this syntax so the model
 *     can read the nudge, judge whether session-local is genuinely right
 *     THIS time, and re-invoke with the marker + justification. The
 *     justification is logged to stderr for the audit trail. Without this
 *     override the hook would be a hard wall — the intent is a nudge, not
 *     a ban.
 * ---------------------------------------------------------------------------
 *
 * BEHAVIOUR
 *
 *   tool               interactive session                worker session
 *   ----------------   --------------------------------  --------------
 *   CronCreate         BLOCK-with-override -> durable    pass (silent)
 *   ScheduleWakeup     if delaySeconds >= 3600:            pass (silent)
 *                        BLOCK-with-override -> durable
 *                      else:
 *                        pass (silent)                    pass (silent)
 *   (anything else)    pass (silent)                     pass (silent)
 *
 * The ScheduleWakeup threshold reflects the tool's own clamp: 3600s
 * (60 min) is the maximum delay the harness accepts, so a caller pinning
 * that value is asking for the longest gap the tool can offer, which is
 * exactly where session-local becomes risky. Anything shorter (a normal
 * prfix-style poll waiting for CI) is left silent so the hook adds
 * near-zero noise on the common case.
 *
 * Worker sessions are silent-passed for the same reason as the agent
 * guardrail: workers run short-lived polls scoped to a task, and the
 * anti-pattern the guardrail exists to catch (long-horizon schedule that
 * outlives its session) doesn't apply to them.
 *
 * GRACEFUL DEGRADATION
 *
 * No Sonata round-trip is required — the alternatives named in the block
 * reason are documentation, not calls, so this hook does not fail-open on
 * a Sonata outage the way the agent guardrail does. Any internal error
 * still passes the call through with a stderr warning; a hook that wedges
 * the session is worse than the pattern it guards against.
 *
 * ROLE DETECTION
 *
 * Same env-var contract as the agent guardrail:
 *   worker      -> SONA_WORKER=1
 *   interactive -> everything else
 */

"use strict";

// Harness tools this hook guards. Matched against Claude Code's PreToolUse
// tool_name field. The matcher declared in Sonata's ensureBundledHooks()
// keeps the hook off the process spawn path for every other tool.
const GUARDED_TOOLS = new Set(["CronCreate", "ScheduleWakeup"]);

// ScheduleWakeup only fires the block when the caller pinned the maximum
// clamp — anything shorter is treated as a normal prfix-style poll and
// passed silently. AE IV's suggested heuristic: keep noise near zero on
// the common case, catch the long-horizon intent that motivated the
// filing in the first place. The clamp value comes from ScheduleWakeup's
// own tool definition: [60, 3600] per the harness.
const SCHEDULE_WAKEUP_LONG_DELAY_THRESHOLD_SECONDS = 3600;

// Per-call override marker. The model reads a block reason naming this
// syntax explicitly, decides whether the redirect is right THIS time, and
// if not, re-invokes with this prefix on whichever string field the tool
// takes. Matches at the START of the trimmed field only — a stray
// occurrence deep in a long prompt cannot accidentally authorise
// unrelated work. Reason is logged to stderr for the audit trail.
const OVERRIDE_MARKER_RE = /^\s*\[sonata-scheduler-approved:\s*([^\]]+)\]\s*/;

/** Pass the tool call through. Exit 0 with no stdout = no decision. */
function pass() {
  process.exit(0);
}

/** Emit a block decision and exit.
 *
 * Both the modern and legacy shapes are emitted deliberately — see the
 * agent-guardrail's equivalent for the reasoning (CLI version drift).
 */
function block(reason) {
  process.stdout.write(
    JSON.stringify({
      decision: "block",
      reason,
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    }),
  );
  process.exit(0);
}

/** worker | interactive — same env contract as the agent guardrail. */
function sessionRole() {
  if (process.env.SONA_WORKER === "1") return "worker";
  return "interactive";
}

/** Fields on a scheduling tool_input that may carry the override marker.
 *
 * CronCreate uses `description` for the human label and `prompt` for what
 * the harness re-invokes. ScheduleWakeup uses `reason` and `prompt`.
 * Scanning all three keeps the model from having to remember which field
 * belongs to which tool — the marker works wherever they put it.
 */
const OVERRIDE_MARKER_FIELDS = ["reason", "description", "prompt"];

function findOverrideMarker(input) {
  for (const field of OVERRIDE_MARKER_FIELDS) {
    const value = input[field];
    if (typeof value !== "string") continue;
    const m = value.match(OVERRIDE_MARKER_RE);
    if (m) return { field, reason: m[1].trim() };
  }
  return null;
}

function redirectReason(toolName, input) {
  const scheduleDesc =
    typeof input.description === "string" && input.description.trim()
      ? input.description.trim().slice(0, 120)
      : typeof input.prompt === "string" && input.prompt.trim()
        ? input.prompt.trim().split("\n")[0].slice(0, 120)
        : typeof input.reason === "string" && input.reason.trim()
          ? input.reason.trim().slice(0, 120)
          : "(unlabelled)";

  const lines = [
    `Session-local ${toolName} blocked.`,
    "",
    `Schedule label: ${scheduleDesc}`,
    "",
    "The harness's session-local scheduling primitives (CronCreate,",
    "ScheduleWakeup) die when THIS session exits. A next-morning",
    "verification, a durable poll across restarts, or anything the user is",
    "counting on to fire while they sleep silently disappears with the",
    "session — no error, no notification.",
    "",
    "Sonata's scheduler is durable and survives restarts. Use one of:",
    "",
    "  calendar_create   — one-shot Claude prompt at a specific time",
    "                      (e.g. 'tomorrow 8am ET', 'in 6 hours', ISO ts).",
    "                      Best for the 'run this check ONCE at time T' case.",
    "",
    "  scheduler_create  — recurring cron job. Cron expr / interval / daily /",
    "                      weekly forms all accepted. Best for 'every 15 min'",
    "                      or 'every weekday at 9am' cases.",
    "",
    "Both dispatch through the same worker pool the guardrail-redirected",
    "background-Agent flow uses, so anything they fire is visible in the",
    "Workers UI, DM-able, and leaves a transcript.",
    "",
    "PER-CALL OVERRIDE — if session-local is genuinely correct here (a",
    "short poll tied to THIS conversation that MUST end when it does), you",
    "can bypass this block by re-invoking with any string field prefixed:",
    "",
    "  [sonata-scheduler-approved: <one-line reason>]",
    "",
    "The justification is captured in the hook's stderr for the audit",
    "trail. Use sparingly — the default is Sonata's durable scheduler.",
    "",
    "To bypass deliberately for this session: CLAUDE_ALLOW_SESSION_SCHEDULE=1",
  ];

  return lines.join("\n");
}

function shouldGuard(toolName, input) {
  if (toolName === "CronCreate") return true;
  if (toolName === "ScheduleWakeup") {
    // ScheduleWakeup's delaySeconds can arrive as number or string depending
    // on JSON re-serialisation upstream. Coerce and range-check; anything
    // outside the numeric threshold reads as short-poll and passes silently.
    const raw = input.delaySeconds;
    const seconds = typeof raw === "number" ? raw : Number(raw);
    if (!Number.isFinite(seconds)) return false;
    return seconds >= SCHEDULE_WAKEUP_LONG_DELAY_THRESHOLD_SECONDS;
  }
  return false;
}

function main(raw) {
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    // Unparseable stdin is not a reason to break the session.
    return pass();
  }

  if (!payload || typeof payload.tool_name !== "string") return pass();
  if (!GUARDED_TOOLS.has(payload.tool_name)) return pass();

  const input =
    payload.tool_input && typeof payload.tool_input === "object"
      ? payload.tool_input
      : {};

  if (process.env.CLAUDE_ALLOW_SESSION_SCHEDULE === "1") {
    process.stderr.write(
      `[scheduler-guardrail] CLAUDE_ALLOW_SESSION_SCHEDULE=1 — allowing ` +
        `session-local ${payload.tool_name}. This schedule dies when the ` +
        `session exits.\n`,
    );
    return pass();
  }

  // Worker sessions use session-local scheduling freely — the anti-pattern
  // (long-horizon schedule outliving its session) doesn't apply to short-
  // lived task-scoped workers. Silent pass to keep worker throughput off
  // the hook's log wall.
  if (sessionRole() === "worker") return pass();

  if (!shouldGuard(payload.tool_name, input)) return pass();

  // Per-call override: model previously read a block reason naming this
  // syntax and re-invoked with justification. Log the reason for the audit
  // trail and pass through.
  const marker = findOverrideMarker(input);
  if (marker) {
    process.stderr.write(
      `[scheduler-guardrail] OVERRIDE (tool=${payload.tool_name}, field=${marker.field}) — ` +
        `reason: ${marker.reason}\n`,
    );
    return pass();
  }

  return block(redirectReason(payload.tool_name, input));
}

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  try {
    main(raw);
  } catch (err) {
    // Fail open, but say so.
    process.stderr.write(
      `[scheduler-guardrail] internal error, passing tool call through: ${
        err && err.message ? err.message : String(err)
      }\n`,
    );
    process.exit(0);
  }
});
