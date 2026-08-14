#!/usr/bin/env node
// Verification harness for pre-tool-use-scheduler-guardrail.js.
//
// The scheduler guardrail makes no HTTP calls (the alternatives named in
// its block reason are documentation, not API surface), so testing is
// just: spawn the hook with a synthetic PreToolUse payload on stdin,
// assert exit code and (for block cases) stdout JSON shape.
//
// Spawns the hook asynchronously — same rationale as the agent-guardrail
// harness. spawnSync would freeze the parent loop; not strictly necessary
// here (no HTTP) but keeps the pattern uniform and reads consistent.

"use strict";
const { spawn } = require("node:child_process");
const path = require("node:path");

const HOOK = path.join(__dirname, "pre-tool-use-scheduler-guardrail.js");

function runHook({ payload, env = {} }) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [HOOK], {
      env: { ...process.env, ...env, PATH: process.env.PATH || "" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (c) => (stdout += c));
    child.stderr.on("data", (c) => (stderr += c));
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({ code, stdout, stderr });
    });
    child.stdin.write(JSON.stringify(payload));
    child.stdin.end();
  });
}

function assert(cond, msg) {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}

function parseDecision(stdout) {
  if (!stdout) return null;
  try { return JSON.parse(stdout); } catch { return null; }
}

async function withCleanEnv(fn) {
  // Ensure the escape-hatch env var isn't leaked from the caller shell
  // and that we're in the "interactive" role branch by default.
  const prev = {
    CLAUDE_ALLOW_SESSION_SCHEDULE: process.env.CLAUDE_ALLOW_SESSION_SCHEDULE,
    SONA_WORKER: process.env.SONA_WORKER,
  };
  delete process.env.CLAUDE_ALLOW_SESSION_SCHEDULE;
  delete process.env.SONA_WORKER;
  try {
    return await fn();
  } finally {
    if (prev.CLAUDE_ALLOW_SESSION_SCHEDULE !== undefined) {
      process.env.CLAUDE_ALLOW_SESSION_SCHEDULE = prev.CLAUDE_ALLOW_SESSION_SCHEDULE;
    }
    if (prev.SONA_WORKER !== undefined) {
      process.env.SONA_WORKER = prev.SONA_WORKER;
    }
  }
}

const TESTS = [];
function test(name, fn) { TESTS.push({ name, fn }); }

// ─── Guarded-tool detection ─────────────────────────────────────────

test("passes silently on non-scheduling tools", async () => {
  const { code, stdout } = await runHook({
    payload: { tool_name: "Bash", tool_input: { command: "ls" } },
  });
  assert(code === 0, `exit code was ${code}`);
  assert(stdout === "", `stdout should be empty, got: ${stdout}`);
});

test("passes silently on ScheduleWakeup with short delay", async () => {
  const { code, stdout } = await runHook({
    payload: {
      tool_name: "ScheduleWakeup",
      tool_input: { delaySeconds: 300, prompt: "poll ci" },
    },
  });
  assert(code === 0);
  assert(stdout === "", `expected silent pass on short ScheduleWakeup, got: ${stdout}`);
});

test("passes silently on ScheduleWakeup with delay just under threshold", async () => {
  const { code, stdout } = await runHook({
    payload: {
      tool_name: "ScheduleWakeup",
      tool_input: { delaySeconds: 3599, prompt: "poll ci" },
    },
  });
  assert(code === 0);
  assert(stdout === "");
});

// ─── Block path ──────────────────────────────────────────────────────

test("blocks CronCreate in an interactive session", async () => {
  const { code, stdout } = await runHook({
    payload: {
      tool_name: "CronCreate",
      tool_input: {
        cron: "0 8 * * *",
        prompt: "Verify scout #537 stamped correctly",
        description: "verify scout 537",
      },
    },
  });
  assert(code === 0);
  const decision = parseDecision(stdout);
  assert(decision, `expected JSON decision on stdout, got: ${stdout}`);
  assert(decision.decision === "block", "top-level decision must be 'block' for CLI back-compat");
  assert(decision.hookSpecificOutput?.permissionDecision === "deny", "modern-shape permissionDecision must be 'deny'");
  assert(/calendar_create/.test(decision.reason), "reason should name calendar_create");
  assert(/scheduler_create/.test(decision.reason), "reason should name scheduler_create");
  assert(/sonata-scheduler-approved/.test(decision.reason), "reason should name the override marker");
});

test("blocks ScheduleWakeup at the 3600s clamp", async () => {
  const { code, stdout } = await runHook({
    payload: {
      tool_name: "ScheduleWakeup",
      tool_input: {
        delaySeconds: 3600,
        prompt: "check overnight batch",
        reason: "long-horizon batch verification",
      },
    },
  });
  assert(code === 0);
  const decision = parseDecision(stdout);
  assert(decision?.decision === "block");
});

test("coerces string delaySeconds and blocks at threshold", async () => {
  const { code, stdout } = await runHook({
    payload: {
      tool_name: "ScheduleWakeup",
      tool_input: { delaySeconds: "3600", prompt: "long wait" },
    },
  });
  assert(code === 0);
  assert(parseDecision(stdout)?.decision === "block", "string '3600' should coerce and block");
});

// ─── Escape hatches ──────────────────────────────────────────────────

test("CLAUDE_ALLOW_SESSION_SCHEDULE=1 passes with audit stderr", async () => {
  const { code, stdout, stderr } = await runHook({
    payload: {
      tool_name: "CronCreate",
      tool_input: { cron: "0 8 * * *", prompt: "something durable" },
    },
    env: { CLAUDE_ALLOW_SESSION_SCHEDULE: "1" },
  });
  assert(code === 0);
  assert(stdout === "", "must not emit a block decision on env-bypass");
  assert(/CLAUDE_ALLOW_SESSION_SCHEDULE=1/.test(stderr), "must audit the bypass");
});

test("override marker in `reason` field passes with audit stderr", async () => {
  const { code, stdout, stderr } = await runHook({
    payload: {
      tool_name: "ScheduleWakeup",
      tool_input: {
        delaySeconds: 3600,
        reason: "[sonata-scheduler-approved: short poll tied to this thread only]",
        prompt: "loop",
      },
    },
  });
  assert(code === 0);
  assert(stdout === "");
  assert(/OVERRIDE.*field=reason/.test(stderr), `expected OVERRIDE line naming reason field; got: ${stderr}`);
  assert(/short poll tied to this thread only/.test(stderr), "must log the caller's justification");
});

test("override marker in `description` field passes with audit stderr", async () => {
  const { code, stdout, stderr } = await runHook({
    payload: {
      tool_name: "CronCreate",
      tool_input: {
        cron: "*/5 * * * *",
        description: "[sonata-scheduler-approved: session-scoped debug poll]",
        prompt: "debug",
      },
    },
  });
  assert(code === 0);
  assert(stdout === "");
  assert(/field=description/.test(stderr));
});

test("override marker in `prompt` field also passes", async () => {
  const { code, stdout, stderr } = await runHook({
    payload: {
      tool_name: "CronCreate",
      tool_input: {
        cron: "0 * * * *",
        prompt: "[sonata-scheduler-approved: no reason field on this tool] hourly ping",
      },
    },
  });
  assert(code === 0);
  assert(stdout === "");
  assert(/field=prompt/.test(stderr));
});

test("override marker mid-string does NOT bypass (anchored at start)", async () => {
  const { code, stdout } = await runHook({
    payload: {
      tool_name: "CronCreate",
      tool_input: {
        cron: "0 8 * * *",
        prompt: "Verify scout, and see [sonata-scheduler-approved: X] in the log",
      },
    },
  });
  assert(code === 0);
  assert(parseDecision(stdout)?.decision === "block", "marker deep in prompt must not authorise");
});

// ─── Worker session behaviour ────────────────────────────────────────

test("worker sessions get silent pass on CronCreate", async () => {
  const { code, stdout, stderr } = await runHook({
    payload: { tool_name: "CronCreate", tool_input: { cron: "0 * * * *", prompt: "poll" } },
    env: { SONA_WORKER: "1" },
  });
  assert(code === 0);
  assert(stdout === "", "worker must not see a block");
  assert(stderr === "", "worker path should be truly silent");
});

test("worker sessions get silent pass on ScheduleWakeup at 3600s", async () => {
  const { code, stdout, stderr } = await runHook({
    payload: {
      tool_name: "ScheduleWakeup",
      tool_input: { delaySeconds: 3600, prompt: "long wait for CI" },
    },
    env: { SONA_WORKER: "1" },
  });
  assert(code === 0);
  assert(stdout === "");
  assert(stderr === "");
});

// ─── Malformed input ─────────────────────────────────────────────────

test("unparseable stdin passes through silently (do not break sessions)", async () => {
  // Bypass runHook (which stringifies payload) and feed raw bad JSON directly.
  const result = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [HOOK], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    child.stdout.on("data", (c) => (stdout += c));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout }));
    child.stdin.write("{ not json");
    child.stdin.end();
  });
  assert(result.code === 0, `exit code was ${result.code}`);
  assert(result.stdout === "", "malformed stdin must not emit a block");
});

test("missing tool_name passes silently", async () => {
  const { code, stdout } = await runHook({ payload: { tool_input: {} } });
  assert(code === 0);
  assert(stdout === "");
});

// ─── Runner ──────────────────────────────────────────────────────────

(async () => {
  let passed = 0;
  let failed = 0;
  await withCleanEnv(async () => {
    for (const t of TESTS) {
      try {
        await t.fn();
        console.log(`  ✓ ${t.name}`);
        passed++;
      } catch (err) {
        console.error(`  ✗ ${t.name}`);
        console.error(`      ${err.message}`);
        failed++;
      }
    }
  });
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
})();
