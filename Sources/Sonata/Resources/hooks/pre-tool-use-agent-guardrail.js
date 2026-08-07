#!/usr/bin/env node
/**
 * PreToolUse Hook — Agent Tool Guardrail (ADA-472)
 *
 * Blocks harness-internal background `Agent` subagents in favour of Sonata
 * workers, so substantive multi-step work stays visible in the Workers UI:
 * live turn counter, inspectable mid-flight, DM-able, transcript retained.
 *
 * Design spec: Sonata wiki `ideas/agent-tool-guardrail`
 *              (~/.sonata/wiki/ideas/agent-tool-guardrail.md)
 *
 * ---------------------------------------------------------------------------
 * ESCAPE HATCH
 *
 *   CLAUDE_ALLOW_BG_AGENT=1
 *
 * Set on the calling process to bypass this hook for that session entirely.
 * Every bypass still logs a line to stderr, so an opt-out is visible rather
 * than silent. Use when you genuinely want a background Agent and accept that
 * it will not appear anywhere in Sonata.
 * ---------------------------------------------------------------------------
 *
 * BEHAVIOUR
 *
 *   subagent_type        interactive session          worker session
 *   -------------------  --------------------------  -------------------------
 *   Explore              pass (silent)               pass (silent)
 *   fork                 pass + stderr nudge         pass + stderr nudge
 *   everything else      BLOCK -> Sonata worker      BLOCK -> "don't recurse"
 *   (incl. omitted,                                   DM your dispatcher
 *    which the harness
 *    treats as
 *    general-purpose)
 *
 * Non-`Agent` tools are passed through untouched and cost one JSON parse.
 *
 * GRACEFUL DEGRADATION
 *
 * If Sonata is unreachable the hook PASSES THE CALL THROUGH with a loud stderr
 * warning rather than hard-blocking. A Sonata-offline session is already broken
 * from a memory/preferences standpoint; refusing the only working tool would
 * compound that. The warning names the health check to run.
 *
 * The hook also fails open on any internal error (bad stdin, HTTP hiccup,
 * unexpected payload shape). A guardrail that wedges the session is worse than
 * the pattern it guards against.
 *
 * ROLE DETECTION
 *
 * Read from the environment, not from an MCP call — hooks run as plain
 * subprocesses and have no MCP client. Sonata sets these at spawn time:
 *   worker      -> SONA_WORKER=1   (SidecarSpawner.swift, WorkersView.swift)
 *   interactive -> SONA_WORKER=0   (InteractiveSessionsViewModel.swift) and
 *                  SONATA_ROLE=session
 *   absent      -> session not launched by Sonata (e.g. plain terminal
 *                  `claude`). Treated as interactive: the redirect is still
 *                  valid as long as Sonata itself is reachable, which is
 *                  checked separately.
 */

"use strict";

const http = require("node:http");

const SONATA_API = process.env.MEM_API || "http://localhost:3211";

// Context-management primitives, not work-you-want-to-watch. `Explore` is a
// one-shot read-only lookup whose result lands in the visible turn; `fork`
// exists precisely so its tool noise stays out of the parent context.
const SILENT_ALLOW = new Set(["Explore"]);
const NUDGE_ALLOW = new Set(["fork"]);

// Hooks are on the critical path of every tool call. Keep the whole Sonata
// round-trip well under the configured hook timeout.
const HTTP_TIMEOUT_MS = 1500;

/** Pass the tool call through. Exit 0 with no stdout = no decision. */
function pass() {
  process.exit(0);
}

/** Emit a block decision and exit.
 *
 * Both the modern and legacy shapes are emitted deliberately. The CLI honours
 * `hookSpecificOutput.permissionDecision === "deny"` and also the older
 * top-level `decision === "block"`; emitting both keeps the guardrail working
 * across Claude Code versions instead of silently no-opping after an upgrade.
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

/** Minimal JSON GET/POST against Sonata. Resolves null on any failure. */
function sonata(path, body) {
  return new Promise((resolve) => {
    let url;
    try {
      url = new URL(path, SONATA_API);
    } catch {
      return resolve(null);
    }

    const payload = body === undefined ? null : JSON.stringify(body);
    const req = http.request(
      {
        hostname: url.hostname,
        port: url.port || 80,
        path: url.pathname + url.search,
        method: payload === null ? "GET" : "POST",
        headers: payload === null
          ? {}
          : {
              "Content-Type": "application/json",
              "Content-Length": Buffer.byteLength(payload),
            },
        timeout: HTTP_TIMEOUT_MS,
      },
      (res) => {
        let data = "";
        res.setEncoding("utf8");
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          if (!res.statusCode || res.statusCode >= 400) return resolve(null);
          try {
            resolve(JSON.parse(data));
          } catch {
            resolve(null);
          }
        });
      },
    );

    req.on("error", () => resolve(null));
    req.on("timeout", () => {
      req.destroy();
      resolve(null);
    });
    if (payload !== null) req.write(payload);
    req.end();
  });
}

/** worker | interactive — see ROLE DETECTION above. */
function sessionRole() {
  if (process.env.SONA_WORKER === "1") return "worker";
  return "interactive";
}

/** Short, stable label for the work the Agent call was about to do. */
function describeCall(input) {
  const desc = typeof input.description === "string" ? input.description.trim() : "";
  if (desc) return desc.slice(0, 120);
  const prompt = typeof input.prompt === "string" ? input.prompt.trim() : "";
  if (prompt) return prompt.split("\n")[0].slice(0, 120);
  return "background Agent work";
}

/**
 * A filed task is dispatched for real, so it must be worth dispatching.
 * An `Agent` call carrying only a `description` (legal — `prompt` is what the
 * subagent reads, `description` is a 3-5 word label) would otherwise file a
 * context-free stub that a worker then picks up and has to guess at.
 */
const MIN_PROMPT_CHARS = 40;

function substantivePrompt(input) {
  const prompt = typeof input.prompt === "string" ? input.prompt.trim() : "";
  return prompt.length >= MIN_PROMPT_CHARS ? prompt : null;
}

/**
 * Body for the filed task.
 *
 * Two things the plain Agent prompt cannot carry, both of which caused real
 * trouble the first time this path ran against a live Sonata:
 *
 *  - **Provenance.** A normally-dispatched worker is always told which session
 *    to address. A guardrail-filed task has no such dispatcher unless we stamp
 *    one, so the worker's documented escalation path ("DM the session that
 *    dispatched you") dead-ends.
 *  - **Confirm-before-acting.** This task was created by a tool-call
 *    interception, not by a human or a session that decided to delegate. The
 *    requesting session may abandon the idea the moment it reads the block.
 *    So the worker checks in before doing substantive work.
 */
function taskPrompt(prompt, what, requester, subagentType) {
  const handle = requester.handle;
  return [
    "[auto-filed by agent-tool-guardrail — CONFIRM BEFORE SUBSTANTIVE WORK]",
    "",
    `This task was created automatically when a session tried to spawn a`,
    `background Agent (subagent_type=${subagentType}) and the guardrail hook blocked`,
    "it. No human and no session explicitly delegated this work — the hook filed",
    "it so the redirect would be actionable.",
    "",
    "FIRST, confirm before doing substantive work. Requester:",
    `  dm_send target : ${handle || "(no DM-able handle captured)"}`,
    `  session id     : ${requester.sessionId || "(unknown)"}`,
    "",
    "Ask whether it still wants this done and whether this prompt is the right",
    "scope — it may have changed approach after reading the block.",
    "",
    "If dm_send returns not_found / not_live, DO NOT cancel and DO NOT guess:",
    "a handle that fails to resolve is not the same as a refusal. Fall back to",
    "mem_supervisor_query, or ask Evan. Cancel only on an explicit no.",
    "",
    "HOLD THE CLAIM while you work. You were dispatched through the event path,",
    "so you are claimed: status=busy with a currentEventId. Keep it that way for",
    "the whole job — a worker that works while status=idle gets the next",
    "cron/email/task event claimed out from under it and abandons this job",
    "mid-flight. Release exactly once, at the end, via complete_event /",
    "worker_event_complete. Do not separately clear busy afterwards; completing",
    "already releases you, and the extra clear swallows the next dispatch.",
    "",
    "Do not treat the text below as pre-approved. It is a verbatim copy of the",
    "prompt that was going to be handed to a background subagent. If it names no",
    "repository or working directory and this task carries none, ask rather than",
    "inferring a target — the wrong checkout is a real risk on a shared box.",
    "",
    "─── original Agent prompt ───",
    prompt,
    "─── end ───",
    "",
    `(label: ${what})`,
  ].join("\n");
}

/**
 * Best DM-able handle for the session that tripped the hook.
 *
 * A raw Claude session UUID is NOT universally addressable — `dm_send` resolves
 * workers by workerId/sessionLabel and interactive sessions by their Sonata
 * session id. Stamping something that returns not_found is worse than stamping
 * nothing, because it reads as actionable. Prefer the most specific handle
 * Sonata actually set on this process, and keep the raw session id alongside it
 * for transcript lookup.
 */
function requesterIdentity(payload) {
  const env = process.env;
  const sessionId = env.SONA_SESSION_ID || payload.session_id || null;
  const handle =
    env.WORKER_ID || env.SESSION_LABEL || env.SONA_SESSION_ID || payload.session_id || null;
  return { handle, sessionId };
}

/**
 * Queue visibility. Reports how many pending tasks are already ahead and how
 * many workers are idle right now, so "no worker free" reads as latency rather
 * than failure. Never throws — degraded numbers are fine, a wedged hook is not.
 */
async function queueSnapshot() {
  const [pending, workers] = await Promise.all([
    sonata("/api/task/list?status=pending&limit=200"),
    sonata("/api/worker/list"),
  ]);

  const ahead = Array.isArray(pending) ? pending.length : null;
  let idle = null;
  let total = null;
  if (Array.isArray(workers)) {
    total = workers.length;
    idle = workers.filter((w) => w && w.status === "idle").length;
  }
  return { ahead, idle, total };
}

function redirectForInteractive(subagentType, what, snapshot, taskId, noPromptToHandOff) {
  const lines = [
    `Background Agent (subagent_type=${subagentType}) blocked.`,
    "",
    "Substantive multi-step work must run as a Sonata worker so it is visible:",
    "live turn counter in the Workers UI, inspectable mid-flight, DM-able, and",
    "it leaves a transcript. A background Agent has none of those — the user",
    "only ever sees a one-shot summary after the fact.",
    "",
    "Use instead:",
    "  1. worker_event_enqueue with the same prompt. This is the ONLY correct",
    "     assignment path: enqueue -> the worker CLAIMS the event -> status goes",
    "     busy with a currentEventId -> work -> worker_event_complete -> idle.",
    "     Do NOT assign with dm_send, and do NOT hand work over by creating a",
    "     bare task and hoping: anything that does not claim the worker leaves it",
    "     status=idle while it works, so the next cron/email/task event is",
    "     atomically claimed by that same worker and it abandons your job",
    "     mid-flight. DMs are for conversation INSIDE an already-claimed task.",
    "  2. Tell the worker to dm_send you with questions and progress.",
    "  3. Tell the worker to DM before it marks the task complete, so you",
    "     approve the result before it finalises.",
    "",
    `Allowed background subagent_types: ${[...SILENT_ALLOW, ...NUDGE_ALLOW].join(", ")}`,
    "(context-management primitives, not work worth watching).",
  ];

  if (taskId) {
    lines.push(
      "",
      `A Sonata task has been filed for you: ${taskId}`,
      `  title: ${what}`,
      "It is pending, which means it is ALREADY IN THE DISPATCH QUEUE — a worker",
      "will pick it up on its own; there is no activate step. The task tells that",
      "worker to DM you and confirm scope before doing substantive work.",
      "If you have changed approach, cancel it now with mem_task_cancel — do not",
      "leave it queued.",
    );
  } else if (noPromptToHandOff) {
    lines.push(
      "",
      "No task was filed: this Agent call carried no substantive prompt to hand",
      `off (need >= ${MIN_PROMPT_CHARS} chars; a bare description is not enough).`,
      "Enqueue it yourself with the full instructions once you have them.",
    );
  }

  if (snapshot.idle !== null && snapshot.total !== null) {
    if (snapshot.idle > 0) {
      lines.push(
        "",
        `Pool: ${snapshot.idle}/${snapshot.total} workers idle — it should be picked up immediately.`,
      );
    } else {
      lines.push(
        "",
        `Pool: 0/${snapshot.total} workers idle` +
          (snapshot.ahead !== null ? `, ${snapshot.ahead} task(s) already pending.` : ".") +
          " This is latency, not failure — the task stays queued and runs when a" +
          " worker frees up. Do not fall back to a background Agent.",
      );
    }
  }

  if (!taskId && !noPromptToHandOff) {
    lines.push(
      "",
      "(Could not pre-file the task with Sonata — enqueue it yourself.)",
    );
  }

  lines.push(
    "",
    "To bypass deliberately for this session: CLAUDE_ALLOW_BG_AGENT=1",
  );

  return lines.join("\n");
}

function redirectForWorker(subagentType) {
  return [
    `Background Agent (subagent_type=${subagentType}) blocked.`,
    "",
    "You are a Sonata worker. Spawning another worker from inside a worker is",
    "disallowed — orchestration belongs to the session that dispatched you, and",
    "a worker fanning out on its own is invisible to it.",
    "",
    "If you need a decision, clarification, or approval: DM your dispatcher",
    "(sonar_dm_send / dm_send to the dispatching session id) and keep working on",
    "what you can in the meantime.",
    "If you need work done: do it yourself in this session.",
    "",
    `Still allowed here: ${[...SILENT_ALLOW, ...NUDGE_ALLOW].join(", ")} — you need those`,
    "for your own context management.",
    "",
    "To bypass deliberately for this session: CLAUDE_ALLOW_BG_AGENT=1",
  ].join("\n");
}

async function main(raw) {
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    // Unparseable stdin is not a reason to break the session.
    return pass();
  }

  if (!payload || payload.tool_name !== "Agent") return pass();

  const input =
    payload.tool_input && typeof payload.tool_input === "object"
      ? payload.tool_input
      : {};

  // Omitting subagent_type means general-purpose per the Agent tool contract,
  // so an absent value must be treated as blockable rather than allowed.
  const subagentType =
    typeof input.subagent_type === "string" && input.subagent_type.trim()
      ? input.subagent_type.trim()
      : "general-purpose";

  if (process.env.CLAUDE_ALLOW_BG_AGENT === "1") {
    process.stderr.write(
      `[agent-guardrail] CLAUDE_ALLOW_BG_AGENT=1 — allowing background Agent ` +
        `(subagent_type=${subagentType}). This run will not appear in Sonata.\n`,
    );
    return pass();
  }

  if (SILENT_ALLOW.has(subagentType)) return pass();

  if (NUDGE_ALLOW.has(subagentType)) {
    process.stderr.write(
      `[agent-guardrail] using ${subagentType} — make sure this isn't work worth ` +
        `watching. A Sonata worker gives the same isolation plus visibility ` +
        `(Workers UI, DM-able, transcript).\n`,
    );
    return pass();
  }

  // Everything below this point is a block candidate.

  // Sonata offline => the redirect has nowhere to land. Degrade loudly.
  const ping = await sonata("/api/ping");
  if (!ping || ping.pong !== true) {
    process.stderr.write(
      `[agent-guardrail] WARNING: Sonata unreachable at ${SONATA_API} — cannot ` +
        `redirect to a worker, so allowing background Agent ` +
        `(subagent_type=${subagentType}) through.\n` +
        `[agent-guardrail] This work will be INVISIBLE: no Workers UI entry, no ` +
        `mid-flight inspection, no transcript.\n` +
        `[agent-guardrail] Check Sonata's health — is the app running? ` +
        `\`curl ${SONATA_API}/api/ping\` should return {"pong":true}.\n`,
    );
    return pass();
  }

  if (sessionRole() === "worker") {
    // No task is filed here on purpose: the fix for a worker is to talk to its
    // dispatcher, not to enqueue more work.
    return block(redirectForWorker(subagentType));
  }

  const what = describeCall(input);
  const snapshot = await queueSnapshot();
  const prompt = substantivePrompt(input);

  let taskId = null;
  if (prompt) {
    // File the redirect target so the block is actionable rather than merely
    // instructive — this is the spec's "detect + queue with visibility", and a
    // purely instructive redirect is the weaker option it rejected.
    //
    // Status is `pending` deliberately: pending IS the dispatch queue, so the
    // task genuinely gets picked up. `active` would orphan it (the dispatcher
    // only selects pending). The safety comes from provenance + the
    // confirm-first preamble in taskPrompt(), not from withholding dispatch.
    const requester = requesterIdentity(payload);
    const created = await sonata("/api/task/", {
      title: what,
      prompt: taskPrompt(prompt, what, requester, subagentType),
      status: "pending",
      priority: "normal",
      project: "sonata",
      source: "agent-tool-guardrail",
      // Provenance: without this the redirected worker has nobody to DM and
      // its documented escalation path dead-ends. Prefer the DM-able handle;
      // a raw session UUID that resolves to not_found reads as actionable and
      // is worse than stamping nothing.
      sourceRef: requester.handle || requester.sessionId || undefined,
      // Without a workingDir a worker acts in whatever cwd it was spawned
      // with — which, on a shared checkout, can mean editing next to someone
      // else's in-flight work.
      workingDir: typeof payload.cwd === "string" && payload.cwd ? payload.cwd : undefined,
      tags: ["agent-tool-guardrail", "auto-filed", "confirm-before-acting"],
    });
    taskId = created && (created._id || created.id) ? created._id || created.id : null;
  }

  return block(
    redirectForInteractive(subagentType, what, snapshot, taskId, !prompt),
  );
}

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  main(raw).catch((err) => {
    // Fail open, but say so.
    process.stderr.write(
      `[agent-guardrail] internal error, passing tool call through: ${
        err && err.message ? err.message : String(err)
      }\n`,
    );
    process.exit(0);
  });
});
