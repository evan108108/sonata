#!/usr/bin/env node
// ADA-472 verification harness.
//
// Runs the guardrail hook against a STUB Sonata so the block path can be
// exercised end-to-end (including task filing) with zero live side effects.
// An earlier round hit the real scheduler and dispatched synthetic tasks to
// real workers; that is what this stub exists to prevent.
//
// NOTE: the hook is spawned ASYNCHRONOUSLY on purpose. A previous version used
// spawnSync, which freezes the parent event loop — so the in-process stub
// server could never answer the child's HTTP calls, every block path timed out
// into the Sonata-offline branch, and the suite reported 21 false failures.
// Keep this async.

"use strict";
const http = require("node:http");
const { spawn } = require("node:child_process");

const path = require("node:path");
const HOOK = path.join(__dirname, "pre-tool-use-agent-guardrail.js");

let lastPost = null;
let poolIdle = 2;
const poolTotal = 6;

const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const send = (obj) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    if (req.url.startsWith("/api/ping")) return send({ pong: true });
    if (req.url.startsWith("/api/worker/list")) {
      const ws = [];
      for (let i = 0; i < poolTotal; i++) {
        ws.push({ workerId: `w${i}`, status: i < poolIdle ? "idle" : "busy" });
      }
      return send(ws);
    }
    if (req.url.startsWith("/api/task/list")) {
      return send([{ _id: "p1" }, { _id: "p2" }, { _id: "p3" }]);
    }
    if (req.url.startsWith("/api/task/")) {
      try {
        lastPost = JSON.parse(body);
      } catch {
        lastPost = { PARSE_ERROR: body };
      }
      return send({ _id: "STUB-TASK-0001" });
    }
    res.writeHead(404);
    res.end("{}");
  });
});

function runHook(payload, env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [HOOK], {
      env: { ...process.env, ...env },
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (c) => (out += c));
    child.stderr.on("data", (c) => (err += c));
    child.on("close", () => {
      let decision = null;
      if (out.trim()) {
        try {
          decision = JSON.parse(out);
        } catch {
          decision = { UNPARSEABLE: out };
        }
      }
      resolve({ decision, stderr: err.trim() });
    });
    child.stdin.end(typeof payload === "string" ? payload : JSON.stringify(payload));
  });
}

const results = [];
function check(name, cond, detail) {
  results.push({ name, pass: !!cond });
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${detail ? "\n        " + detail : ""}`);
}

const agent = (t, extra) => ({
  hook_event_name: "PreToolUse",
  tool_name: "Agent",
  session_id: "session-TEST-123",
  cwd: "/Users/evan/testcwd",
  tool_input: Object.assign(
    t ? { subagent_type: t } : {},
    { prompt: "Audit every route handler under app/routes for missing auth checks and report a punch list." },
    extra || {},
  ),
});

server.listen(0, "127.0.0.1", async () => {
  const API = `http://127.0.0.1:${server.address().port}`;
  const INT = { SONA_WORKER: "0", MEM_API: API, SONA_SESSION_ID: "session-TEST-123" };
  const WRK = { SONA_WORKER: "1", MEM_API: API, SONA_SESSION_ID: "worker-TEST-9" };
  let r;

  console.log("\n=== 1. Non-Agent tool passes untouched ===");
  r = await runHook({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "ls" } }, INT);
  check("Bash / interactive -> pass untouched", r.decision === null && r.stderr === "");

  console.log("\n=== 2. Allowlist (context-management primitives) ===");
  r = await runHook(agent("Explore"), INT);
  check("Explore / interactive -> pass, silent", r.decision === null && r.stderr === "");
  r = await runHook(agent("Explore"), WRK);
  check("Explore / worker -> pass, silent", r.decision === null && r.stderr === "");
  r = await runHook(agent("fork"), INT);
  check("fork / interactive -> pass + stderr nudge", r.decision === null && /work worth watching/.test(r.stderr));
  r = await runHook(agent("fork"), WRK);
  check("fork / worker -> pass + stderr nudge", r.decision === null && /same isolation plus visibility/.test(r.stderr));

  console.log("\n=== 3. Interactive block + filed-task provenance ===");
  lastPost = null;
  r = await runHook(agent("Plan"), INT);
  const reason = r.decision ? r.decision.reason : "";
  check("Plan / interactive -> block", r.decision && r.decision.decision === "block");
  check("  emits modern permissionDecision=deny", r.decision && r.decision.hookSpecificOutput.permissionDecision === "deny");
  check("  task id surfaced in reason", /STUB-TASK-0001/.test(reason));
  check("  pool visibility present", /Pool: 2\/6 workers idle/.test(reason));
  check("  no bogus 'activate' step", !/mem_task_activate/.test(reason));
  check("  PROVENANCE sourceRef = requesting session", lastPost && lastPost.sourceRef === "session-TEST-123", `sourceRef=${lastPost && lastPost.sourceRef}`);
  check("  PROVENANCE workingDir from payload cwd", lastPost && lastPost.workingDir === "/Users/evan/testcwd", `workingDir=${lastPost && lastPost.workingDir}`);
  check("  filed status = pending (dispatchable)", lastPost && lastPost.status === "pending");
  check("  prompt has confirm-first preamble", lastPost && /CONFIRM BEFORE SUBSTANTIVE WORK/.test(lastPost.prompt));
  check("  prompt names requesting session", lastPost && lastPost.prompt.includes("session-TEST-123"));
  check("  prompt carries original verbatim", lastPost && /missing auth checks/.test(lastPost.prompt));
  check("  machine-checkable tags", lastPost && lastPost.tags.includes("agent-tool-guardrail") && lastPost.tags.includes("confirm-before-acting"));
  check("  CLAIM: names worker_event_enqueue as the path", /worker_event_enqueue/.test(reason));
  check("  CLAIM: warns dm_send does not claim", /Do NOT assign with dm_send/.test(reason));
  check("  CLAIM: explains idle-while-working preemption", /status=idle while it works/.test(reason));
  check("  CLAIM: no longer offers mem_task_create as equivalent", !/or mem_task_create/.test(reason));
  check("  CLAIM: task prompt says hold the claim", lastPost && /HOLD THE CLAIM while you work/.test(lastPost.prompt));
  check("  CLAIM: task prompt says release once via complete", lastPost && /Release exactly once/.test(lastPost.prompt));
  check("  CLAIM: warns against clearing busy after complete", lastPost && /extra clear swallows the next dispatch/.test(lastPost.prompt));
  check("  handle fallback is escalate, not cancel", lastPost && /DO NOT cancel and DO NOT guess/.test(lastPost.prompt));

  console.log("\n=== 4. Omitted subagent_type defaults to general-purpose ===");
  r = await runHook(agent(null), INT);
  check("omitted -> blocked as general-purpose", r.decision && /subagent_type=general-purpose/.test(r.decision.reason));

  console.log("\n=== 5. No substantive prompt -> block WITHOUT filing ===");
  lastPost = null;
  r = await runHook(
    { hook_event_name: "PreToolUse", tool_name: "Agent", session_id: "s", cwd: "/tmp", tool_input: { subagent_type: "Plan", description: "plan it" } },
    INT,
  );
  check("bare description -> still blocks", r.decision && r.decision.decision === "block");
  check("  did NOT file a task", lastPost === null);
  check("  explains why no task was filed", r.decision && /No task was filed/.test(r.decision.reason));

  console.log("\n=== 6. Worker block (workers don't recurse) ===");
  lastPost = null;
  r = await runHook(agent("Plan"), WRK);
  check("Plan / worker -> block", r.decision && r.decision.decision === "block");
  check("  worker-specific message", r.decision && /Spawning another worker from inside a worker/.test(r.decision.reason));
  check("  tells worker to DM its dispatcher", r.decision && /DM your dispatcher/.test(r.decision.reason));
  check("  files NO task from a worker", lastPost === null);

  console.log("\n=== 7. Escape hatch ===");
  r = await runHook(agent("Plan"), { ...INT, CLAUDE_ALLOW_BG_AGENT: "1" });
  check("CLAUDE_ALLOW_BG_AGENT=1 -> pass", r.decision === null);
  check("  logs the bypass to stderr", /CLAUDE_ALLOW_BG_AGENT=1/.test(r.stderr));

  console.log("\n=== 8. Sonata offline -> graceful degrade ===");
  r = await runHook(agent("Plan"), { ...INT, MEM_API: "http://127.0.0.1:1" });
  check("offline -> pass, not blocked", r.decision === null);
  check("  warns the work will be INVISIBLE", /INVISIBLE/.test(r.stderr));
  check("  hints at the health check", /api\/ping/.test(r.stderr));

  console.log("\n=== 9. Pool exhausted -> queued, no Agent fallback ===");
  poolIdle = 0;
  r = await runHook(agent("Plan"), INT);
  const r9 = r.decision ? r.decision.reason : "";
  check("pool full -> STILL blocks", r.decision && r.decision.decision === "block");
  check("  reports 0 idle + pending count", /Pool: 0\/6 workers idle, 3 task\(s\) already pending/.test(r9), (r9.split("\n").find((l) => l.startsWith("Pool:")) || "").slice(0, 100));
  check("  frames as latency not failure", /latency, not failure/.test(r9));
  check("  forbids falling back to Agent", /Do not fall back to a background Agent/.test(r9));
  poolIdle = 2;

  console.log("\n=== 10. Fails open on malformed input ===");
  r = await runHook("not json at all", INT);
  check("garbage stdin -> pass", r.decision === null);

  const failed = results.filter((x) => !x.pass);
  console.log(`\n${"=".repeat(60)}\n${results.length - failed.length}/${results.length} checks passed`);
  failed.forEach((f) => console.log("  FAILED: " + f.name));
  server.close();
  process.exit(failed.length ? 1 : 0);
});
