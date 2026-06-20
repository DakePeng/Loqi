# Summary Writing Quality Design

## Goal

Make generated summaries read more smoothly and less repetitively while keeping the current grounded map-reduce architecture.

The first improvement target is writing quality: a more natural overview, cleaner bullets, and fewer repeated phrases. This does not change live mapping, cached notes, stored session shape, or the UI.

## Current Context

Loqi already maps transcript chunks into structured `SummaryRecord` data, then reduces those records into a final markdown summary. Live recordings may precompute chunk notes during silence, and saved sessions reuse cached `chunkNotes` for cheap re-summarization. Recent work restored synthesized reduce output and fixed fallback behavior, so this design stays in that reduce layer instead of replacing the pipeline.

## Non-Goals

- No second LLM polish pass.
- No summary evidence UI or clickable citations.
- No changes to `SessionRecord` schema.
- No changes to live chunking, ASR, diarization, imports, or re-transcription.
- No new dependency.

## Design

### Reduce Prompt

Tighten `PromptBuilder.reduceSummaryPrompt` so the model still emits tagged lines, but with clearer writing constraints:

- The overview should be one natural reader-facing paragraph, not pasted note fragments.
- Section bullets should add new detail and avoid repeating the overview.
- Bullets should be concise complete thoughts, not clipped labels.
- Repeated lead-ins across bullets should be avoided.
- Names, numbers, dates, and decisions must remain exactly grounded in the notes.
- Tone stays style-specific:
  - Meeting: crisp decisions, actions, risks, and open questions.
  - Memo: direct, useful notes to self.
  - Lecture: study-note clarity.
  - Brainstorm: distinct ideas and next steps.
  - Journal: reflective but not flowery.

The output format remains the same: tagged lines parsed into overview plus style sections.

### Local Cleanup

After parsing structured reduce output and before markdown rendering, run a tiny dedup pass over the parsed overview and section items:

- Keep overview lines first.
- Drop section items that are exact or near-duplicates of overview lines or earlier section items.
- Use the existing normalization/similarity utilities (`SummaryEngine.dedupKey` and current `HotwordMatcher.similarity` style).
- Do not rewrite text locally; only drop duplicates.

This is deliberately conservative. It improves repeated summaries without giving local code responsibility for prose generation.

### Fallback Behavior

The existing fallback renderer remains the safety net when model output is unusable or degenerate. It should not gain new behavior except, if needed, sharing the same tiny cross-section duplicate guard already used by `SummaryRecordReducer`.

## Data Flow

1. Map phase produces existing `SessionRecord.ChunkNote` / `SummaryRecord` data.
2. `SummaryEngine.reduceInput` builds note lines as it does today.
3. `reduceSummaryPrompt` asks for better written tagged output.
4. `parseStructuredSummary` parses the tagged output.
5. A new small cleanup step removes repeated parsed items.
6. `renderSummaryMarkdown` renders the same markdown shape used today.

## Error Handling

If the model ignores the format, repeats degenerate text, or returns empty parsed output, the current fallback path still runs. Cleanup must never make a non-empty summary empty unless all items are duplicates; in that case the overview remains.

## Testing

Add focused unit coverage only:

- `reduceSummaryPrompt` contains the writing-quality constraints and keeps the tagged output contract.
- Parsed structured summaries drop section bullets that duplicate the overview or prior bullets.
- Non-duplicate bullets survive cleanup.
- Existing fallback-renderer behavior still passes.

## Acceptance Criteria

- No schema, UI, or migration changes.
- No second LLM generation.
- Re-summarizing an existing session still reuses cached notes.
- Generated summaries should be less repetitive in overview/section overlap.
- Current summary tests continue to pass, with new tests covering the cleanup.
