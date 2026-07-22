#!/usr/bin/env node
/**
 * Sidecar Stop Hook
 *
 * Fires when Claude finishes a response turn. POSTs a memory_request event
 * to the Sonata bridge so the memory sidecar can produce hint files for the
 * NEXT prompt this session sends.
 *
 * Reads sidecar config from ~/.sonata/config/sidecars.json; skips if the
 * memory sidecar is `.off`.
 *
 * Silent-on-failure: a broken sidecar must never break the session — worse
 * than a missed hint is a broken terminal, and hints are advisory anyway.
 */

const fs = require("fs");
const path = require("path");
const http = require("http");
const os = require("os");

const SIDECAR_NAME = "memory";
// A memory_request arrives as a sonata-bridge channel event; these markers
// appear in its opening tag and body. Only the head of the prompt is scanned
// so a user quoting an old event mid-message doesn't suppress their own hints.
const MEMORY_REQUEST_MARKERS = ['event_type="memory_request"', "[MEMORY_REQUEST]"];
const MEMORY_REQUEST_SCAN_CHARS = 400;
const SONATA_DATA_DIR = process.env.SONATA_DATA_DIR || path.join(os.homedir(), ".sonata");
const CONFIG_PATH = path.join(SONATA_DATA_DIR, "config", "sidecars.json");
const SCRATCH_DIR = path.join(SONATA_DATA_DIR, "scratch");
const SONATA_PORT = Number(process.env.SONATA_PORT) || 3211;

const DEFAULT_CONFIG = {
  tier: "standard",
  subscriptionCapPct: 20,
  judgeModel: "haiku",
  contextDepth: "plusAssistantHead",
  topK: 10,
  triggers: ["stop_hook"],
  dedupWindow: 20,
  rotationThreshold: 70,
};

let input = "";
process.stdin.setEncoding("utf-8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  try { run(JSON.parse(input)); }
  catch (err) { fail(err); }
});

function run(hookInput) {
  // Prevent re-fire on stop-hook continuation loops.
  if (hookInput.stop_hook_active) return done();

  const sessionId = hookInput.session_id;
  if (!sessionId) return done();

  // Role gate. Every Claude Code session on this machine loads the same
  // ~/.claude/settings.json hook chain, INCLUDING pool workers, sidecars, and
  // the supervisor. Without this gate they'd each fire a memory_request every
  // time they finished a turn — the supervisor's "SILENT." echo storm on
  // 2026-07-22 came from exactly that. A memory hint is only useful for a
  // session that's going to accept a NEXT USER PROMPT; anything else is noise.
  if (!isUserSession(hookInput)) return done();

  const config = readConfig();
  if (config.tier === "off") return done();
  if (!(config.triggers || []).includes("stop_hook")) return done();

  const lastAssistantHead = extractAssistantHead(hookInput, config.contextDepth);
  const lastUserPrompt = extractLastUserPrompt(hookInput.transcript_path);

  // A session whose own turn was a memory_request is a sidecar worker draining
  // the queue. Enqueueing for it makes every completion spawn its successor,
  // each carrying the previous request quoted verbatim as its "context" — a
  // self-sustaining run of zero-hint requests that never terminates.
  if (isMemoryRequestTurn(lastUserPrompt)) return done();

  const alreadyInjected = readInjectedLedger(sessionId, config.dedupWindow || 20);

  const payload = {
    source_session_id: sessionId,
    trigger: "stop_hook",
    recent_context: {
      last_user_prompt: lastUserPrompt,
      last_assistant_head: lastAssistantHead,
    },
    already_injected: alreadyInjected,
    budget_tier: config.tier,
    judge_model: config.judgeModel,
    top_k: config.topK,
    dedup_window: config.dedupWindow,
  };

  enqueueAndExit({
    type: "memory_request",
    payload: JSON.stringify(payload),
    priority: 4,
  });
}

function readConfig() {
  try {
    const raw = fs.readFileSync(CONFIG_PATH, "utf-8");
    const all = JSON.parse(raw);
    const own = all[SIDECAR_NAME];
    if (!own) return DEFAULT_CONFIG;
    return { ...DEFAULT_CONFIG, ...own };
  } catch {
    return DEFAULT_CONFIG;
  }
}

function extractAssistantHead(hookInput, depth) {
  const full = hookInput.last_assistant_message || "";
  if (!full) return "";
  if (depth === "full") return full;
  if (depth === "lastPrompt") return "";
  return full.slice(0, 2000);
}

function extractLastUserPrompt(transcriptPath) {
  if (!transcriptPath || !fs.existsSync(transcriptPath)) return "";
  try {
    const lines = fs.readFileSync(transcriptPath, "utf-8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (!line) continue;
      let obj;
      try { obj = JSON.parse(line); } catch { continue; }
      // Claude Code transcripts wrap the actual message in { type, message: {...} }
      const msg = obj.message || obj;
      if (!msg || msg.role !== "user") continue;
      const content = msg.content;
      if (typeof content === "string") return content.slice(0, 4000);
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block && block.type === "text" && typeof block.text === "string") {
            return block.text.slice(0, 4000);
          }
        }
      }
    }
  } catch {}
  return "";
}

function isMemoryRequestTurn(lastUserPrompt) {
  if (!lastUserPrompt) return false;
  const head = lastUserPrompt.slice(0, MEMORY_REQUEST_SCAN_CHARS);
  return MEMORY_REQUEST_MARKERS.some(marker => head.includes(marker));
}

// True when this Claude Code invocation is a human-facing session, false for
// anything Sonata launched as a worker / sidecar / supervisor.
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

function readInjectedLedger(sessionId, windowTurns) {
  const ledgerPath = path.join(SCRATCH_DIR, `injected-memory-${sanitizeSession(sessionId)}.jsonl`);
  if (!fs.existsSync(ledgerPath)) return [];
  try {
    const lines = fs.readFileSync(ledgerPath, "utf-8").split("\n").filter(Boolean);
    const recent = lines.slice(-windowTurns);
    const out = [];
    for (const line of recent) {
      try {
        const rec = JSON.parse(line);
        if (rec.memoryId) out.push(rec.memoryId);
      } catch {}
    }
    return out;
  } catch {
    return [];
  }
}

function sanitizeSession(id) {
  return String(id).replace(/[^A-Za-z0-9._-]/g, "");
}

function enqueueAndExit(body) {
  // Write hook decision first so Claude Code has the response even if the
  // POST hangs; then keep the process alive just long enough to flush the
  // request and get its response. Hard cap at 2s so a broken bridge never
  // stalls a session's turn.
  process.stdout.write(JSON.stringify({}));

  const data = JSON.stringify(body);
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    process.exit(0);
  };
  const killer = setTimeout(finish, 2000);
  killer.unref();

  const req = http.request({
    host: "127.0.0.1",
    port: SONATA_PORT,
    path: "/api/worker/events/enqueue",
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(data),
    },
    timeout: 1500,
  }, res => {
    res.on("data", () => {});
    res.on("end", finish);
  });
  req.on("error", finish);
  req.on("timeout", () => { try { req.destroy(); } catch {} finish(); });
  req.write(data);
  req.end();
}

function done() {
  process.stdout.write(JSON.stringify({}));
  process.exit(0);
}

function fail(err) {
  try { process.stderr.write(`sidecar-stop-hook error: ${err && err.message}\n`); } catch {}
  process.stdout.write(JSON.stringify({}));
  process.exit(0);
}
