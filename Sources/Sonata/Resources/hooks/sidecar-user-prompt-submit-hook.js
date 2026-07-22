#!/usr/bin/env node
/**
 * Sidecar UserPromptSubmit Hook
 *
 * Fires when the user submits a prompt. Fetches any hints the memory sidecar
 * wrote for this session from Sonata's sidecarHints table via /api/sidecar/
 * hint/pop (read-and-delete in one transaction), prepends them to the prompt
 * Claude sees.
 *
 * Also, on High-tier config with the submit_refine trigger enabled, fires a
 * follow-up memory_request carrying the actual submitted prompt as context —
 * strictly better retrieval than the stop-hook's payload, which is built
 * before the user has typed the next thing.
 *
 * Silent-on-failure: hints are advisory. A broken bridge, a config parse
 * error, an HTTP timeout — none of it justifies breaking the prompt.
 */

const fs = require("fs");
const path = require("path");
const http = require("http");
const os = require("os");

const SIDECAR_NAME = "memory";
const SONATA_DATA_DIR = process.env.SONATA_DATA_DIR || path.join(os.homedir(), ".sonata");
const CONFIG_PATH = path.join(SONATA_DATA_DIR, "config", "sidecars.json");
const SONATA_PORT = Number(process.env.SONATA_PORT) || 3211;

let input = "";
process.stdin.setEncoding("utf-8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  try { run(JSON.parse(input)); }
  catch { done(); }
});

function run(hookInput) {
  const sessionId = hookInput && hookInput.session_id;
  if (!sessionId) return done();

  // Role gate: symmetric with sidecar-stop-hook.js. Only user sessions have a
  // "next prompt" that benefits from injected hints.
  if (!isUserSession(hookInput)) return done();

  const config = readConfig();
  if (config && config.tier === "off") return done();

  // Kick off the hint pop and (optionally) the submit_refine enqueue in
  // parallel — both are fire-and-forget HTTP POSTs to Sonata, capped by
  // a hard 2s ceiling so a broken bridge can't stall the prompt.
  popHintsThenExit(sessionId, hookInput, config);
}

function popHintsThenExit(sessionId, hookInput, config) {
  const triggers = (config && Array.isArray(config.triggers)) ? config.triggers : [];
  const submitRefineEnabled = triggers.includes("submit_refine");

  let popped = false;
  let refineDone = !submitRefineEnabled; // no wait needed if refine disabled
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    process.exit(0);
  };
  const killer = setTimeout(finish, 2000);
  killer.unref();

  const tryFinish = () => { if (popped && refineDone) finish(); };

  postJSON("/api/sidecar/hint/pop", { sessionId }, 1500, (err, body) => {
    if (!err && body && typeof body.content === "string" && body.content.trim()) {
      const content = body.content.trim();
      const wrapped = `<user-prompt-submit-hook>\n${content}\n</user-prompt-submit-hook>`;
      try { process.stdout.write(wrapped); } catch {}
      // Record the memory ids that just got injected so the next stop-hook
      // can pass them as `already_injected`. Without this the whole dedup
      // pathway is dead — the stop hook reads this ledger by design, but
      // the previous tier-2 rewrite of this hook dropped the append. That
      // silently defeated the `dedupWindow` setting: turning it up made no
      // difference because `already_injected` was always empty.
      recordInjections(sessionId, content);
    }
    popped = true;
    tryFinish();
  });

  if (submitRefineEnabled && hookInput.prompt) {
    const payload = {
      source_session_id: sessionId,
      trigger: "submit_refine",
      recent_context: {
        last_user_prompt: String(hookInput.prompt).slice(0, 4000),
        last_assistant_head: "",
      },
      already_injected: [],
      budget_tier: (config && config.tier) || "high",
      judge_model: (config && config.judgeModel) || "haiku",
      top_k: (config && config.topK) || 10,
      dedup_window: (config && config.dedupWindow) || 20,
    };
    postJSON("/api/worker/events/enqueue", {
      type: "memory_request",
      payload: JSON.stringify(payload),
      priority: 4,
    }, 1500, () => {
      refineDone = true;
      tryFinish();
    });
  }
}

function postJSON(pathStr, body, timeoutMs, cb) {
  const data = JSON.stringify(body);
  const req = http.request({
    host: "127.0.0.1",
    port: SONATA_PORT,
    path: pathStr,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(data),
    },
    timeout: timeoutMs,
  }, res => {
    let raw = "";
    res.on("data", chunk => { raw += chunk; });
    res.on("end", () => {
      let parsed = null;
      try { parsed = JSON.parse(raw); } catch {}
      cb(null, parsed);
    });
  });
  req.on("error", err => cb(err));
  req.on("timeout", () => { try { req.destroy(); } catch {} cb(new Error("timeout")); });
  req.write(data);
  req.end();
}

function recordInjections(sessionId, content) {
  const slug = sanitizeSession(sessionId);
  const ledgerPath = path.join(
    SONATA_DATA_DIR, "scratch", `injected-memory-${slug}.jsonl`
  );
  const ids = extractMemoryIds(content);
  if (ids.length === 0) return;
  const now = Date.now();
  try {
    fs.mkdirSync(path.join(SONATA_DATA_DIR, "scratch"), { recursive: true });
    const lines = ids
      .map(id => JSON.stringify({ memoryId: id, injectedAtMs: now }))
      .join("\n") + "\n";
    fs.appendFileSync(ledgerPath, lines);
  } catch {}
}

function extractMemoryIds(content) {
  // `- **{takeaway}** — [memory: {id}]` — same regex the tier-1 hook used;
  // memory ids from mem_recall are 32-char hex, but memories written by
  // hand can be arbitrary slugs, so keep the character class broad.
  const re = /\[memory:\s*([A-Za-z0-9._:-]+)\s*\]/g;
  const ids = [];
  let m;
  while ((m = re.exec(content)) !== null) ids.push(m[1]);
  return ids;
}

function sanitizeSession(id) {
  return String(id).replace(/[^A-Za-z0-9._-]/g, "");
}

function readConfig() {
  try {
    const raw = fs.readFileSync(CONFIG_PATH, "utf-8");
    const all = JSON.parse(raw);
    return all[SIDECAR_NAME] || null;
  } catch {
    return null;
  }
}

// True when this Claude Code invocation is a human-facing session. Symmetric
// with the check in sidecar-stop-hook.js; keep them in sync.
function isUserSession(hookInput) {
  const role = process.env.SONATA_SESSION_ROLE;
  if (role && role !== "user") return false;
  const cwd = String(hookInput.cwd || process.cwd() || "");
  const home = os.homedir();
  const nonUserPrefixes = [
    `${home}/.sonata/worker`,
    `${home}/.sonata/sidecar-`,
    `${home}/.sonata/supervisor`,
  ];
  if (nonUserPrefixes.some(p => cwd.startsWith(p))) return false;
  return true;
}

function done() {
  process.exit(0);
}
