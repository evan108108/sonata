#!/usr/bin/env node
// Verification harness for pre-tool-use-zsh-trap-guardrail.js.
//
// Two layers: detect() directly over the spec's must-block / must-pass lists,
// then the hook end-to-end (spawned with a synthetic PreToolUse payload) for
// the env gates, the override and the block JSON shape.
//
// Run: node pre-tool-use-zsh-trap-guardrail.test.js   (exit 0 = all pass)

"use strict";
const { spawn } = require("node:child_process");
const path = require("node:path");

const HOOK = path.join(__dirname, "pre-tool-use-zsh-trap-guardrail.js");
const { detect } = require(HOOK);

// Spec for task e57af007. Any false positive on MUST_PASS means don't ship.
const MUST_BLOCK = [
  'git show "$SHA:tests/a"',
  "git show $REF:scout/x",
  "echo ====",
  "echo =====",
  "printf =x",
  'cat "$D:lib/f"',
];
const MUST_PASS = [
  'git show "${SHA}:tests/a"',
  "echo '===='",
  'echo "a=b"',
  "x=$(date)",
  "jq '.a:b'",
  'curl "https://h:443/x"',
];
// Extra shapes found while measuring blast radius / reading the scanner.
const EXTRA_BLOCK = [
  'for f in a b; do echo "$f:tail"; done',
  "cat <<EOF\n$SHA:tests\nEOF",          // unquoted heredoc expands
  "ls && echo ==done==",
];
const EXTRA_PASS = [
  "cat <<'EOF'\n$SHA:tests/a\necho ====\nEOF",  // quoted heredoc: literal
  "cat <<EOF\necho ====\nEOF",                 // heredoc body is data, not a command
  'echo "a =b"',
  "echo \\$SHA:tests",
  'export PATH="$HOME/bin:$PATH"',
  'export PATH=$PATH:/usr/local/bin',
  'curl -u "$USER:$PASS" https://x',
  'echo "$HOST:443"',
  "printf '%s\\n' \"$resp\" | jq .",
  "[ \"$a\" = b ] && echo ok",
];

const TESTS = [];
function test(name, fn) { TESTS.push({ name, fn }); }
function assert(cond, msg) { if (!cond) throw new Error(`assertion failed: ${msg}`); }

for (const c of [...MUST_BLOCK, ...EXTRA_BLOCK]) {
  test(`blocks: ${JSON.stringify(c)}`, () => assert(detect(c).length > 0, "expected a finding"));
}
for (const c of [...MUST_PASS, ...EXTRA_PASS]) {
  test(`passes: ${JSON.stringify(c)}`, () => {
    const f = detect(c);
    assert(f.length === 0, `unexpected finding ${JSON.stringify(f)}`);
  });
}

function runHook(payload, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [HOOK], {
      env: { PATH: process.env.PATH || "", ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (c) => (stdout += c));
    child.stderr.on("data", (c) => (stderr += c));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.stdin.end(JSON.stringify(payload));
  });
}
const WORKER = { SONA_WORKER: "1", SHELL: "/bin/zsh" };
const bash = (command) => ({ tool_name: "Bash", tool_input: { command } });

test("hook: blocks a trap in a zsh worker, with the fix in the reason", async () => {
  const r = await runHook(bash('git show "$SHA:tests/a"'), WORKER);
  assert(r.code === 0, `exit ${r.code}`);
  const d = JSON.parse(r.stdout);
  assert(d.hookSpecificOutput.permissionDecision === "deny", "not deny");
  assert(d.reason.includes('"${SHA}:'), `reason lacks fix: ${d.reason}`);
});
test("hook: echo-equals reason says to quote", async () => {
  const r = await runHook(bash("echo ===="), WORKER);
  assert(JSON.parse(r.stdout).reason.includes("'===='"), "reason lacks quoted fix");
});
test("hook: clean command passes with empty stdout", async () => {
  const r = await runHook(bash('git show "${SHA}:tests/a"'), WORKER);
  assert(r.code === 0 && r.stdout === "", `stdout ${r.stdout}`);
});
test("hook: interactive session (no SONA_WORKER) passes", async () => {
  const r = await runHook(bash("echo ===="), { SHELL: "/bin/zsh" });
  assert(r.stdout === "", "should pass");
});
test("hook: worker with SHELL unset (how Sonata launches workers) blocks", async () => {
  const r = await runHook(bash("echo ===="), { SONA_WORKER: "1" });
  assert(r.stdout !== "", "expected a deny with SHELL unset");
  assert(JSON.parse(r.stdout).hookSpecificOutput.permissionDecision === "deny", "not deny");
});
test("hook: bash shell passes", async () => {
  const r = await runHook(bash("echo ===="), { SONA_WORKER: "1", SHELL: "/bin/bash" });
  assert(r.stdout === "", "should pass");
});
test("hook: non-Bash tool passes", async () => {
  const r = await runHook({ tool_name: "Read", tool_input: { file_path: "/x" } }, WORKER);
  assert(r.stdout === "", "should pass");
});
test("hook: # zsh-trap-ok override passes and logs", async () => {
  const r = await runHook(bash("echo $f:t # zsh-trap-ok: want the tail"), WORKER);
  assert(r.stdout === "" && r.stderr.includes("OVERRIDE"), `stdout ${r.stdout} stderr ${r.stderr}`);
});
test("hook: CLAUDE_ALLOW_ZSH_TRAP=1 passes", async () => {
  const r = await runHook(bash("echo ===="), { ...WORKER, CLAUDE_ALLOW_ZSH_TRAP: "1" });
  assert(r.stdout === "", "should pass");
});
test("hook: garbage stdin fails open", async () => {
  const child = spawn(process.execPath, [HOOK], { env: WORKER });
  let out = "";
  child.stdout.on("data", (c) => (out += c));
  const code = await new Promise((res) => { child.on("close", res); child.stdin.end("not json"); });
  assert(code === 0 && out === "", "should fail open");
});

(async () => {
  let failed = 0;
  for (const t of TESTS) {
    try { await t.fn(); console.log(`ok   ${t.name}`); }
    catch (e) { failed++; console.log(`FAIL ${t.name}: ${e.message}`); }
  }
  console.log(`${TESTS.length - failed}/${TESTS.length} passed`);
  process.exit(failed ? 1 : 0);
})();
