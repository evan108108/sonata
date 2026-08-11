---
name: meeting
description: Turn a meeting transcript into Sonata memory. Reads a transcript file (Zoom/Meet/Gemini/manual paste), extracts the Meeting entity, per-person entities, decisions, action items, and key quotes, and lands them in the memory graph with entity edges so `mem_recall` picks them up cross-referenced with everything else. Trigger phrases: `/meeting`, "process this transcript", "extract this meeting", "log this stand up".
---

# /meeting — Turn a meeting transcript into memory

## When to use

The user pastes a transcript, points at a transcript file path, or asks to log a meeting. Fires the extraction pass end-to-end: entities, decisions, action items, quotes → `mem_store` + `mem_entity_upsert` with graph edges.

## Inputs

The user may provide any subset of:
- **Transcript** — a file path (`/Users/evan/Documents/meetings/*.md`), pasted text in the prompt, or clipboard content. If none provided, ask for one.
- **Participants** — optional; extract from the transcript if the format uses speaker labels (Gemini Notes and most transcription tools do).
- **Date** — optional; extract from the transcript header or file name. Default to file mtime.
- **Project** — optional; infer from the topics discussed (adaptengine / engineable / sonata / etc). Ask if genuinely ambiguous.
- **Source** — optional; infer from filename/format ("Notes by Gemini" → gemini-notes; Zoom transcript → zoom; etc).

## Output shape

Land the following in Sonata memory:

### 1. Meeting entity (`mem_entity_upsert`)
- `name`: `"<Meeting title> <YYYY-MM-DD>"` (e.g. `"Stand up 2026-08-10"`)
- `type`: `"meeting"`
- `description`: 1-2 sentence recap — attendees, primary threads, notable outcomes.
- `attributes`: `{ date, duration_min, source_transcript (absolute path), source (tool), project }`

### 2. Person entities (`mem_entity_upsert` per participant, skip if already exists via `mem_entity_by_name`)
- `name`: full name as it appears in the transcript
- `type`: `"person"`
- `description`: role/context if inferable from the transcript (or "AdaptEngine developer" / "External to Enginable" if only role is clear)

### 3. Decisions (`mem_store` per decision)
- `type`: `"decision"`
- `project`: the inferred project
- `topic`: kebab-case slug describing the decision
- `importance`: 5–8 based on scope (people-worker repo placement = 7; billing ping = 4)
- `tags`: `["meeting", "<meeting-slug>", "decision", ...topic-tags]`
- `relations`: `[{entity:"<Meeting name>", relation:"decided_at"}, {entity:"<owner>", relation:"owns"}, {entity:"<decider>", relation:"decided_by"}, {entity:"<opposer>", relation:"opposed_by"}, ...]`
    - `decided_by` — required whenever the transcript makes it clear who ultimately made the call. Different from `owns` (that's who implements). Skip only when the group truly decided together with no single caller.
    - `opposed_by` — optional, one entry per person who pushed back before the decision landed. Omit the key entirely if there was no visible dissent — don't emit an empty placeholder.
    - Every entity referenced must exist as a person entity from step 2. If a name only appears in the decision context and wasn't in the participant list, upsert the person entity first.
- `content`: **`DECISION:`** prefix, then the decision statement, then the *reason* (why this direction), then an anchor quote from the transcript in the speaker's own words. Prose should still name who pushed back and who ultimately decided — the graph edges are for query, the prose is for context on read.

### 4. Action items (`mem_store` per item)
- `type`: `"observation"` (not `"task"` — task creation is a separate opt-in step, see below)
- `topic`: kebab-case slug (`<owner>-<verb>-<object>`)
- `importance`: 4–7 based on urgency + scope
- `tags`: `["meeting", "<meeting-slug>", "action-item", "<owner-first-name>", ...topic-tags]`
- `relations`: `[{entity:"<Meeting name>", relation:"raised_at"}, {entity:"<owner>", relation:"assigned_to"}, ...any others]`
- `content`: **`ACTION ITEM (<owner>):`** prefix, then the deliverable + any due date/context.

### 5. Key quotes (`mem_store` per notable quote)
- `type`: `"observation"`
- `topic`: `quote-<speaker-first-name>-<topic-slug>`
- `importance`: 5–7 (higher for load-bearing statements — design principles, strategic direction — 4–5 for color)
- `tags`: `["meeting", "<meeting-slug>", "quote", "<speaker-first-name>", ...topic-tags]`
- `relations`: `[{entity:"<Meeting name>", relation:"said_at"}, {entity:"<speaker>", relation:"speaker"}]`
- `content`: **`KEY QUOTE (<Speaker Name>[, context]):`** followed by the verbatim quote in double-quotes, followed by 1-2 sentences on why it's notable (what it anchors, what it signals).

## Content hygiene

- Memory `content` fields are **plain prose only**. No trailing XML tags, no closing `</content>` / `</invoke>` fragments — those are format artifacts from internal templating that must not leak into stored bodies.
- Quote punctuation in content bodies as regular characters (`"..."`), not escaped or wrapped. `mem_store` takes plain text; no XML/HTML/JSON escaping needed.
- If a body ends with anything that isn't the last sentence's punctuation, it's a bug — strip it.

## Selection heuristics

**What counts as a decision** — a group choice that closes off an alternative. Not "we should think about X" (open) but "we're doing Y, not Z" (closed). Include the rejected alternative and the reason if visible in transcript.

**What counts as an action item** — a specific person committing to a specific deliverable. "Someone should look into that" is not an action item; "Theo will walk Sai's diagram" is.

**What counts as a key quote** — statements that (a) anchor a load-bearing design principle, (b) signal strategic direction, or (c) are worth remembering verbatim for later reference. Skip small talk and coordination cross-talk.

**What NOT to extract** — social pleasantries, tech-issue cross-talk, off-topic tangents (unless they carry a decision). The transcript being interrupted by a Sonos false-alarm doesn't need a memory. Personality color goes in the Meeting entity's `description`, not standalone memories.

## After extraction — optional next steps

Ask the user (once, batched):
1. **File action items as tasks?** Iterate action items, offer `mem_task_create` per owner. Some action items (small pings) are memory-only, others (multi-day deliverables) become tasks.
2. **Index the full transcript as a doc?** `mem_doc_index` the transcript file so `mem_doc_search` picks it up. Recommended for stand-ups and longer meetings; skip for very short syncs.
3. **Report summary.** Print the count of each item type (meeting entity, N decisions, M action items, K quotes) and the meeting-entity id so the user can `mem_expand` from it later.

## Naming conventions

- Meeting entity names: `"Stand up 2026-08-10"`, `"BD Sync — MLA 2026-08-05"`, `"1:1 with Theo 2026-08-07"` — human-readable, ISO date at the end.
- Meeting slug for tags: `standup-2026-08-10`, `bd-sync-mla-2026-08-05` — kebab-case, embed the date.
- Person entities: full name as written in the transcript. Don't collapse "Sai" and "Sairam Yellanki" into two entities — resolve to canonical name via `mem_entity_by_name` first, or store nicknames as attribute.

## Testing

First-run test transcript: `/Users/evan/Documents/meetings/Stand up - 2026_08_10 10_30 EDT - Notes by Gemini.md` — processed 2026-08-10, produced Meeting entity `27098ba2f27a47959e7b71d9c0e639a1` with 7 person entities, 3 decisions, 6 action items, 2 key quotes. Reference implementation for shape-check on future runs.
