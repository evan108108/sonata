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
# 1. Start llama-server with the locked model
llama-server -m <path-to-Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf> \
  --host 127.0.0.1 --port 7713 \
  --ctx-size 8192 --n-predict 256 --temp 0.3 -ngl 99

# 2. Run the recorder (lives alongside these goldens)
bash Tests/SonataTests/fixtures/pith-golden/record-goldens.sh
```

The recorder pulls memory content from `~/.sonata/sonata.db` by ID.

## Locked configuration

- Model: `llama-3.1-8b-instruct-Q4_K_M`
- Temperature: `0.3`
- Seed: `42` (for reproducibility — llama.cpp honors seed)
- Max tokens: 400
- Response format: `json_object`

## System prompt (locked)

```
You generate LOD summaries for memories. Return STRICT JSON with two fields: l0 and l1. l0 = one sentence, max ~15 words, the thesis or essence. l1 = 2-3 sentences, max ~60 words, the argument arc or key facts. Be abstractive — distill, don't quote. Match the voice of the source (first-person for reflections, third-person for technical notes). For very short input, l0/l1 may equal input. Output ONLY the JSON. No preamble, no markdown fences.
```
