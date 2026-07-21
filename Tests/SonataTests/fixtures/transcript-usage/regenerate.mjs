#!/usr/bin/env node
// Regenerate the transcript-usage fixtures.
//
//   node Tests/SonataTests/fixtures/transcript-usage/regenerate.mjs
//
// WHAT THESE FIXTURES ARE
//
// Reduced captures of real Claude Code session transcripts. `parseTranscriptUsage`
// reads exactly five fields per line — `type`, `isSidechain`, and
// `message.usage.{input_tokens, cache_creation_input_tokens,
// cache_read_input_tokens, output_tokens}` — so a fixture carrying only those
// fields drives the algorithm identically to the multi-megabyte original while
// containing NO conversation content. That is the point: these are committed to
// the repo, and real transcripts are private.
//
// Fidelity is not assumed. This script recomputes the six readings from the full
// originals and from the reductions and refuses to write unless every number
// matches — so a reduction that dropped something load-bearing fails here rather
// than silently weakening the regression baseline.
//
// The `expected.json` it emits is the assertion table SweeperTranscriptUsageTests
// reads. Regenerating is only correct when the SOURCE sessions change; if a code
// change moves these numbers, that is the test doing its job, not a stale fixture.

import { readFileSync, writeFileSync, readdirSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT_DIR = dirname(fileURLToPath(import.meta.url));
const SOURCE_DIR = join(homedir(), ".claude", "projects", "-Users-evan--sonata-worker");

// The six sessions worker-5 validated the algorithm against on 2026-07-21.
// Named, not globbed: the baseline is these specific conversations.
const SESSIONS = [
  "003b2bf9-3691-47fb-8c35-633223b1646c",
  "00e28d99-7356-4eb4-8531-af1203c7c19c",
  "016580d9-cfac-4331-a98c-1b1d7697b3fe",
  "01b63868-2ecb-471c-beb5-1851f78975e9",
  "01fb1f9a-3f72-4acd-9fcc-2a169ec6a915",
  "02539146-57cf-478b-bfdc-333bd8d97bdb",
];

/** Mirror of Swift `parseTranscriptUsage`. Kept in lockstep deliberately —
 * if the two disagree, the fixtures are measuring something the shipping code
 * does not do. */
function parseTranscriptUsage(jsonl) {
  let totalTokens = 0, inputTokens = 0, cacheReadTokens = 0, contextTokens = 0;
  let sawAssistant = false;
  for (const line of jsonl.split("\n")) {
    if (!line) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    if (entry.type !== "assistant") continue;
    if (entry.isSidechain === true) continue;
    const usage = entry.message?.usage;
    if (!usage) continue;
    sawAssistant = true;
    const input = usage.input_tokens || 0;
    const cacheCreate = usage.cache_creation_input_tokens || 0;
    const cacheRead = usage.cache_read_input_tokens || 0;
    const output = usage.output_tokens || 0;
    totalTokens += input + cacheCreate + cacheRead + output;
    inputTokens += input + cacheCreate + cacheRead;
    cacheReadTokens += cacheRead;
    contextTokens = input + cacheCreate + cacheRead;
  }
  return sawAssistant ? { totalTokens, inputTokens, cacheReadTokens, contextTokens } : null;
}

/** Strip every line to the fields the algorithm reads. Non-assistant lines
 * collapse to a bare `{"type": ...}` so the "skips non-assistant entries" path
 * is still exercised by fixture data rather than only by synthetic cases. */
function reduce(jsonl) {
  const out = [];
  for (const line of jsonl.split("\n")) {
    if (!line) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    if (entry.type !== "assistant") {
      out.push(JSON.stringify({ type: entry.type ?? "unknown" }));
      continue;
    }
    const usage = entry.message?.usage;
    if (!usage) { out.push(JSON.stringify({ type: "assistant" })); continue; }
    const reduced = {
      type: "assistant",
      message: {
        usage: {
          input_tokens: usage.input_tokens || 0,
          cache_creation_input_tokens: usage.cache_creation_input_tokens || 0,
          cache_read_input_tokens: usage.cache_read_input_tokens || 0,
          output_tokens: usage.output_tokens || 0,
        },
      },
    };
    if (entry.isSidechain === true) reduced.isSidechain = true;
    out.push(JSON.stringify(reduced));
  }
  return out.join("\n") + "\n";
}

const CONTEXT_WINDOW = 200_000;
mkdirSync(OUT_DIR, { recursive: true });

const expected = [];
let failures = 0;

for (const session of SESSIONS) {
  const sourcePath = join(SOURCE_DIR, `${session}.jsonl`);
  let original;
  try {
    original = readFileSync(sourcePath, "utf-8");
  } catch {
    console.error(`SKIP ${session}: source transcript no longer on disk`);
    failures++;
    continue;
  }

  const truth = parseTranscriptUsage(original);
  const reduced = reduce(original);
  const check = parseTranscriptUsage(reduced);

  const same = truth && check &&
    truth.totalTokens === check.totalTokens &&
    truth.inputTokens === check.inputTokens &&
    truth.cacheReadTokens === check.cacheReadTokens &&
    truth.contextTokens === check.contextTokens;

  if (!same) {
    console.error(`FAIL ${session}: reduction changed the reading`);
    console.error(`  original: ${JSON.stringify(truth)}`);
    console.error(`  reduced:  ${JSON.stringify(check)}`);
    failures++;
    continue;
  }

  writeFileSync(join(OUT_DIR, `${session}.jsonl`), reduced);
  // TRUNCATE, matching the shipping code. `contextPercent` computes
  // `Int((used * 100) / windowTokens)` in Int64 arithmetic, which floors. An
  // earlier hand-validation of these transcripts used Math.round here and
  // recorded 48%/81% for two sessions that the shipping code reads as 47%/80%
  // (47.859 and 80.938 exactly). Rounding is also the wrong direction for a
  // threshold: rounding 69.6% up to 70% would rotate a session early.
  const pct = Math.trunc((check.contextTokens * 100) / CONTEXT_WINDOW);
  const oldProxyPct = Math.trunc(((check.inputTokens + check.cacheReadTokens) * 100) / CONTEXT_WINDOW);
  expected.push({
    session,
    totalTokens: check.totalTokens,
    inputTokens: check.inputTokens,
    cacheReadTokens: check.cacheReadTokens,
    contextTokens: check.contextTokens,
    contextPercentAt200K: pct,
    supersededProxyPercentAt200K: oldProxyPct,
  });
  console.log(
    `ok ${session}  context=${check.contextTokens} (${pct}%)  ` +
    `superseded proxy would have read ${oldProxyPct}%`
  );
}

if (failures > 0) {
  console.error(`\n${failures} fixture(s) failed — nothing written for those. expected.json NOT updated.`);
  process.exit(1);
}

writeFileSync(join(OUT_DIR, "expected.json"), JSON.stringify(expected, null, 2) + "\n");
console.log(`\nwrote ${expected.length} fixtures + expected.json to ${OUT_DIR}`);
