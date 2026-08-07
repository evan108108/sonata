# Pith golden files

These are reference outputs from **llama-3.1-8b-instruct-Q4_K_M** for the 5 memories in
`pith-corpus.json`. They are the bar `Sources/Chat/Pith.swift` must hit when
calling the local llama-server with the system prompt below.

## How `PithRegressionTests.swift` uses them

For each memory in the corpus, the test calls `Pith.generate(content)` and
asserts byte-equal match against the golden file's `l0` and `l1` fields,
plus the structural assertions (length bounds, JSON-clean, non-empty).

## Regenerating

Re-record only after an explicit human review decided that current Llama
outputs are no longer canonical (model upgrade, prompt change, etc.).

```bash
# 1. Start llama-server with the locked model AND the serving flags
#    ChatServerManager actually spawns with (see "Serving flags" below).
llama-server -m ~/.sonata/bin/llama-3.1-8b-instruct-Q4_K_M \
  --host 127.0.0.1 --port 7713 \
  --ctx-size 131072 --parallel 1 -cb --n-predict 400 --temp 0.3 \
  -fa on -b 4096 -ub 2048 --cache-type-k q8_0 --cache-type-v q8_0 -ngl 99

# 2. Run the recorder (lives alongside these goldens)
bash Tests/SonataTests/fixtures/pith-golden/record-goldens.sh
```

The recorder pulls memory content from `~/.sonata/sonata.db` by ID.

## Serving flags are part of the lock

Goldens are byte-equality fixtures, so anything that perturbs the logits
invalidates them — not just the model, prompt, temperature and seed.
`--cache-type-k/v q8_0` and `-fa on` do exactly that.

This bit us silently. The goldens were recorded 2026-06-02 under
`--ctx-size 8192 --n-predict 256` with an f16 KV cache and no flash attention.
`ChatServerManager` later added `-fa on`, larger batches and a q8_0 KV cache to
cut cold prompt-eval time, and from then on **all 5 goldens drifted** — measured
2026-08-06, before any prompt change. Nothing caught it, because the live
comparison only runs under `PITH_LIVE=1`.

So: regenerate against the flags `ChatServerManager` spawns, and update the
command above whenever those change.

## Record against a quiescent server

`--parallel 1 -cb` means concurrent requests share a batch, and a shared batch
perturbs the numerics — so a fixed seed is *not* sufficient for reproducibility
if anything else is talking to the same llama-server. Sonata itself is a client:
it generates pith on every memory write, so a live app will interleave with the
recorder.

Measured 2026-08-06: one golden recorded during contention came out
"…Cloudflare D1 API"; the same request repeated 6× on an idle server returned
"…Cloudflare D1 REST API" every time. One flake in five, silent, and it looks
exactly like a real drift.

Before recording or running `PITH_LIVE=1`, let the app go idle (or point the
recorder at a llama-server nothing else is using). If a single golden drifts
while the other four hold, suspect contention before you suspect the model.

## Locked configuration

- Model: `llama-3.1-8b-instruct-Q4_K_M`
- Temperature: `0.3`
- Seed: `42` (for reproducibility — llama.cpp honors seed)
- Max tokens: 1500 (`Pith.generateMaxTokens`; 400 truncated ~14% mid-JSON)
- Response format: `json_object`
- Serving flags: as in the command above

## System prompt (locked)

Must stay byte-identical to `Pith.systemPrompt`. `PithRegressionTests`
asserts this, so a prompt edit that skips the goldens fails without needing a
live model.

```
You generate LOD summaries for memories. Return STRICT JSON with two fields: l0 and l1. l0 = one sentence, max ~15 words, the thesis or essence. l1 = 2-3 sentences, max ~60 words, the argument arc or key facts. Be abstractive — distill, don't quote. Match the voice of the source (first-person for reflections, third-person for technical notes). For very short input, l0/l1 may equal input. Before emitting, check every claim in l0/l1 against the source: if the source states it as a question, an uncertainty, or two competing readings, your summary must keep it that way ("asks whether X", "X unresolved"). Assert only what the source asserts. Output ONLY the JSON. No preamble, no markdown fences.
```

The final two sentences exist because the abstract layer was observed inventing
resolutions the body never contained (2026-07-26, and 2026-08-05 on memory
`a85d0e6f`). See `PithUncertaintyTests` and the note on `Pith.systemPrompt`.
