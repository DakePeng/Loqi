# Summary Writing Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Loqi summaries read more naturally and repeat themselves less while keeping the grounded map-reduce pipeline.

**Architecture:** Current `main` renders final summaries deterministically from map notes. This plan restores a single grounded structured reduce generation, adds writing-quality constraints to that reduce prompt, and adds a tiny parsed-output duplicate cleanup before markdown rendering. It keeps chunk mapping, live notes, storage, UI, and model selection unchanged.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI app code, existing `LLMService`, existing `PromptBuilder`, existing `SummaryEngine`.

---

## File Structure

- Modify `Loqi/Pipeline/Refinement/PromptBuilder.swift`: add structured reduce prompt, parser, duplicate cleanup, and markdown renderer.
- Modify `Loqi/Pipeline/Summary/SummaryEngine.swift`: add reduce input construction, call one structured LLM reduce, keep deterministic fallback.
- Modify `LoqiTests/SummaryEngineTests.swift`: add prompt/parser/cleanup and reduce fallback tests.
- No schema, UI, dependency, or migration changes.

## Verification Notes

This project requires a real iPhone for runtime verification. Do not use simulator test runs as a substitute.

For each test step below, prefer manual Xcode:

1. Open `Loqi.xcodeproj`.
2. Select the `Loqi` scheme.
3. Select a connected real iPhone.
4. Run the named `LoqiTests/SummaryEngineTests` tests from the Test navigator.

For compile-only CLI verification, use:

```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1
```

Expected compile result after implementation tasks: `** BUILD SUCCEEDED **`.

---

### Task 1: Add Structured Reduce Prompt And Cleanup Tests

**Files:**
- Modify: `LoqiTests/SummaryEngineTests.swift`

- [ ] **Step 1: Add failing tests after `chunkRecordPromptSeparatesContextFromTarget`**

```swift
@Test func reducePromptRequiresNaturalWritingConstraints() {
    let prompt = PromptBuilder().reduceSummaryPrompt(
        notes: "topic: 桌布讨论\nfact: 传家宝桌子不必铺布\nphoto: 桌面照片显示木纹完整",
        style: .meeting,
        in: .chinese,
        sizing: SummaryPromptSizing(
            maxTokens: 420,
            overviewCap: 2,
            sectionCaps: [3, 3, 3]))

    #expect(prompt.system.contains("natural overview"))
    #expect(prompt.system.contains("complete-thought bullets"))
    #expect(prompt.system.contains("Do not repeat the overview"))
    #expect(prompt.system.contains("Avoid repeated lead-ins"))
    #expect(prompt.system.contains("Meeting tone"))
    #expect(prompt.system.contains("Output ONLY tagged lines"))
    #expect(prompt.user.contains("Notes:\ntopic: 桌布讨论"))
}

@Test func structuredReduceOutputRendersMarkdown() {
    let builder = PromptBuilder()
    let sizing = SummaryPromptSizing(maxTokens: 420, overviewCap: 2, sectionCaps: [3, 3, 3])
    let parsed = builder.parseStructuredSummary(
        """
        O: 讨论围绕桌子是否需要铺桌布，以及转椅是否适合久坐。
        T: 传家宝桌子可以不铺布，重点是保留原本状态。
        D: 决定暂时不铺桌布。
        A: 未明确: 继续确认转椅是否舒服
        """,
        style: .meeting,
        sizing: sizing)

    #expect(parsed.overview == ["讨论围绕桌子是否需要铺桌布，以及转椅是否适合久坐。"])
    #expect(parsed.items("T") == ["传家宝桌子可以不铺布，重点是保留原本状态。"])
    #expect(parsed.items("D") == ["决定暂时不铺桌布。"])
    #expect(parsed.items("A") == ["未明确: 继续确认转椅是否舒服"])

    let markdown = builder.renderSummaryMarkdown(parsed, in: .chinese)
    #expect(markdown.contains("## 主题"))
    #expect(markdown.contains("- 传家宝桌子可以不铺布"))
    #expect(markdown.contains("## 决定"))
    #expect(markdown.contains("## 待办事项"))
}

@Test func structuredSummaryCleanupDropsOverviewDuplicates() {
    var parsed = PromptBuilder.ParsedStructuredSummary(style: .meeting)
    parsed.overview = ["讨论围绕桌布和转椅选择。"]
    parsed.sections[0] = [
        "讨论围绕桌布和转椅选择",
        "传家宝桌子可以不铺布，重点是保留原本状态。",
    ]
    parsed.sections[1] = ["暂时不铺桌布。"]

    let cleaned = PromptBuilder().deduplicatedStructuredSummary(parsed)

    #expect(cleaned.overview == ["讨论围绕桌布和转椅选择。"])
    #expect(cleaned.items("T") == ["传家宝桌子可以不铺布，重点是保留原本状态。"])
    #expect(cleaned.items("D") == ["暂时不铺桌布。"])
}
```

- [ ] **Step 2: Verify the tests fail before implementation**

Manual Xcode: run the three new `SummaryEngineTests` tests on a connected real iPhone.

Expected: compile failure naming missing members such as `reduceSummaryPrompt`, `ParsedStructuredSummary`, `parseStructuredSummary`, `renderSummaryMarkdown`, and `deduplicatedStructuredSummary`.

- [ ] **Step 3: Commit the red tests**

```bash
git add LoqiTests/SummaryEngineTests.swift
git commit -m "test: cover structured summary writing"
```

---

### Task 2: Add Structured Reduce Helpers To PromptBuilder

**Files:**
- Modify: `Loqi/Pipeline/Refinement/PromptBuilder.swift`
- Test: `LoqiTests/SummaryEngineTests.swift`

- [ ] **Step 1: Insert this code after `parsedChunkNote(records:)`**

```swift
/// Reduce phase: synthesize extracted, source-grounded note records into
/// the final human summary. The model sees notes, not the raw transcript,
/// so it stays inside the small on-device model's useful range.
func reduceSummaryPrompt(
    notes: String,
    style: SummaryStyle = .meeting,
    in language: AppLanguage,
    sizing: SummaryPromptSizing? = nil
) -> (system: String, user: String) {
    let spec = style.spec
    let overviewCap = sizing?.overviewCap ?? spec.overviewCap
    let sectionClauses = spec.sections.enumerated()
        .map { index, section in
            let cap = sizing?.sectionCaps[safe: index] ?? section.cap
            return "up to \(cap) lines \"\(section.tag): <\(section.hint)>\""
        }
        .joined(separator: ", ")
    let tone = switch style {
    case .meeting:
        "Meeting tone: crisp decisions, actions, risks, and open questions."
    case .memo:
        "Memo tone: direct, useful notes to self."
    case .lecture:
        "Lecture tone: clear study notes with concepts and follow-up questions."
    case .brainstorm:
        "Brainstorm tone: distinct ideas, standouts, and next steps."
    case .journal:
        "Journal tone: reflective but not flowery."
    }
    let system = "\(spec.task) Write entirely in \(language.promptName). "
        + "Synthesize the notes into a reader-friendly summary with a natural overview "
        + "and concise complete-thought bullets. Do not concatenate or copy note/photo "
        + "lines. Do not repeat the overview in section bullets. Avoid repeated lead-ins "
        + "across bullets. \(tone) Plain text, no markdown. Output ONLY tagged lines: "
        + "first 1-\(overviewCap) lines \"O: <\(spec.overviewHint)>\", "
        + "then \(sectionClauses). Use only information from the notes; never invent "
        + "names, numbers, or events. Keep names, numbers, and dates exactly as written "
        + "in the notes. Fold photo details into the relevant topic instead of listing "
        + "photos separately. Skip categories with nothing to report. Merge duplicates. "
        + "No other text."
    return (system, "Notes:\n\(notes)")
}

struct ParsedStructuredSummary {
    let style: SummaryStyle
    var overview: [String] = []
    /// One bucket per spec section, parallel to `style.spec.sections`.
    var sections: [[String]]

    init(style: SummaryStyle = .meeting) {
        self.style = style
        sections = Array(repeating: [], count: style.spec.sections.count)
    }

    var isEmpty: Bool {
        overview.isEmpty && sections.allSatisfy(\.isEmpty)
    }

    /// All content with no markdown scaffolding, for repetition validation.
    var joinedValues: String {
        (overview + sections.flatMap { $0 }).joined(separator: "\n")
    }

    func items(_ tag: String) -> [String] {
        guard let index = style.spec.sections.firstIndex(where: { $0.tag == tag })
        else { return [] }
        return sections[index]
    }
}

/// Parse the reduce model's tagged lines against the style's spec.
/// Untagged output parses empty so the caller can use the deterministic fallback.
func parseStructuredSummary(
    _ raw: String,
    style: SummaryStyle = .meeting,
    sizing: SummaryPromptSizing? = nil
) -> ParsedStructuredSummary {
    let spec = style.spec
    let overviewCap = sizing?.overviewCap ?? spec.overviewCap
    var summary = ParsedStructuredSummary(style: style)
    for line in cleanResponse(raw).split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "##", with: "")
        guard !Self.hasDegenerateRepetition(trimmed) else { continue }
        if let value = tagged(trimmed, "O"), summary.overview.count < overviewCap {
            summary.overview.append(value)
            continue
        }
        for (index, section) in spec.sections.enumerated() {
            let cap = sizing?.sectionCaps[safe: index] ?? section.cap
            if let value = tagged(trimmed, section.tag),
               summary.sections[index].count < cap {
                summary.sections[index].append(value)
                break
            }
        }
    }
    return summary
}

/// Keep overview first, then remove exact or near-duplicate section items.
func deduplicatedStructuredSummary(
    _ parsed: ParsedStructuredSummary
) -> ParsedStructuredSummary {
    var cleaned = ParsedStructuredSummary(style: parsed.style)
    cleaned.overview = parsed.overview
    var seen = parsed.overview
        .map(SummaryEngine.dedupKey)
        .filter { !$0.isEmpty }

    func shouldKeep(_ text: String) -> Bool {
        let key = SummaryEngine.dedupKey(text)
        guard !key.isEmpty else { return false }
        if seen.contains(key) { return false }
        for prior in seen.suffix(24)
        where HotwordMatcher.similarity(prior, key)
            >= SummaryRecordReducer.crossSectionDedupThreshold {
            return false
        }
        seen.append(key)
        return true
    }

    for index in parsed.sections.indices {
        cleaned.sections[index] = parsed.sections[index].filter(shouldKeep)
    }
    return cleaned
}

/// Markdown synthesis from parsed tagged output: overview paragraph, then
/// one "## Heading" section per non-empty category.
func renderSummaryMarkdown(
    _ parsed: ParsedStructuredSummary, in language: AppLanguage
) -> String {
    let parsed = deduplicatedStructuredSummary(parsed)
    var blocks: [String] = []
    if !parsed.overview.isEmpty {
        blocks.append(parsed.overview.joined(separator: " "))
    }
    for (section, items) in zip(parsed.style.spec.sections, parsed.sections)
    where !items.isEmpty {
        let bullets = items.map { "- \($0)" }.joined(separator: "\n")
        blocks.append("## \(section.heading(for: language))\n\(bullets)")
    }
    return blocks.joined(separator: "\n\n")
}
```

- [ ] **Step 2: Verify Task 1 tests pass**

Manual Xcode: run the three new `SummaryEngineTests` tests on a connected real iPhone.

Expected: the three tests pass.

- [ ] **Step 3: Compile check**

```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Loqi/Pipeline/Refinement/PromptBuilder.swift LoqiTests/SummaryEngineTests.swift
git commit -m "feat: add structured summary reduce prompt"
```

---

### Task 3: Add SummaryEngine Reduce Integration Tests

**Files:**
- Modify: `LoqiTests/SummaryEngineTests.swift`

- [ ] **Step 1: Add tests after `structuredSummaryCleanupDropsOverviewDuplicates`**

```swift
@Test func reduceInputLabelsPhotoFactsWithoutRawCaptionDump() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let transcript = SessionRecord.ChunkNote(
        headline: "桌布讨论",
        startedAt: t0,
        facts: ["传家宝桌子不必铺布"],
        decisions: ["暂时不铺桌布"])
    let photo = SessionRecord.Attachment(
        fileName: "desk.jpg",
        timestamp: t0.addingTimeInterval(12),
        vlmDescription: "照片显示木质桌面，桌上没有桌布。")
    let input = SummaryEngine.reduceInput(
        notes: AttachmentNotes.merged([transcript], attachments: [photo]),
        style: .meeting)

    #expect(input.contains("fact: 传家宝桌子不必铺布"))
    #expect(input.contains("decision: 暂时不铺桌布"))
    #expect(input.contains("photo: 照片显示木质桌面，桌上没有桌布。"))
    #expect(!input.contains("📷"))
}

@Test func reduceInputKeepsSpecificLabelForDuplicateDecision() {
    let note = SessionRecord.ChunkNote(
        headline: "预算讨论",
        startedAt: Date(timeIntervalSince1970: 1_000_000),
        facts: ["预算定为 42 万"],
        decisions: ["预算定为 42 万"])

    let input = SummaryEngine.reduceInput(notes: [note], style: .meeting)

    #expect(input.contains("decision: 预算定为 42 万"))
    #expect(!input.contains("fact: 预算定为 42 万"))
}

@Test func reducedSummaryFallsBackWhenStructuredOutputRepeats() {
    let builder = PromptBuilder()
    let sizing = SummaryPromptSizing(maxTokens: 420, overviewCap: 6, sectionCaps: [6, 6, 6])
    let raw = (Array(repeating: "O: 好好", count: 6)
        + Array(repeating: "T: 好好", count: 6))
        .joined(separator: "\n")
    let parsed = builder.parseStructuredSummary(raw, style: .meeting, sizing: sizing)
    let note = SessionRecord.ChunkNote(
        headline: "桌布讨论",
        startedAt: Date(timeIntervalSince1970: 1_000_000),
        facts: ["传家宝桌子不必铺布"])

    let summary = SummaryEngine.renderReducedSummary(
        raw: raw,
        parsed: parsed,
        notes: [note],
        style: .meeting,
        length: .standard,
        in: .chinese,
        stitchDetails: false)

    #expect(!parsed.isEmpty)
    #expect(PromptBuilder.hasDegenerateRepetition(parsed.joinedValues))
    #expect(summary.contains("传家宝桌子不必铺布"))
}
```

- [ ] **Step 2: Verify the tests fail before implementation**

Manual Xcode: run the three new `SummaryEngineTests` tests on a connected real iPhone.

Expected: compile failure naming missing members `reduceInput` and `renderReducedSummary`.

- [ ] **Step 3: Commit the red tests**

```bash
git add LoqiTests/SummaryEngineTests.swift
git commit -m "test: cover summary reduce integration"
```

---

### Task 4: Wire SummaryEngine To One Structured Reduce Generation

**Files:**
- Modify: `Loqi/Pipeline/Summary/SummaryEngine.swift`
- Test: `LoqiTests/SummaryEngineTests.swift`

- [ ] **Step 1: Insert `reduceInput` before the `reduce` function**

```swift
/// Reduce input: one labeled line per extracted record. Photos are
/// labeled as photo context so the final reduce can fold them into the
/// surrounding topic instead of copying captions as standalone summary.
static func reduceInput(
    notes: [SessionRecord.ChunkNote], style: SummaryStyle
) -> String {
    let records = SummaryRecordReducer.deduped(
        SummaryRecordReducer.records(from: notes))
    var seen = Set<String>()
    var recent: [String] = []

    func actionText(_ record: SessionRecord.SummaryRecord) -> String {
        let owner = record.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deadline = record.deadline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var text = record.task?.isEmpty == false ? record.task! : record.text
        if !owner.isEmpty, owner != "未明确" {
            text = "\(owner): \(text)"
        }
        if !deadline.isEmpty, deadline != "未明确" {
            text += " (\(deadline))"
        }
        return text
    }

    func labelAndText(_ record: SessionRecord.SummaryRecord) -> (String, String)? {
        switch record.kind {
        case .topic:
            return ("topic", record.topicTitle?.isEmpty == false
                ? record.topicTitle! : record.text)
        case .point:
            return (record.source == .photo ? "photo" : "fact", record.text)
        case .decision:
            return ("decision", record.text)
        case .action:
            return ("action", actionText(record))
        case .question:
            return ("question", record.text)
        case .risk:
            return ("risk", record.text)
        case .term:
            guard style.spec.includeTermsInNotes else { return nil }
            return ("term", record.text)
        case .reflection:
            return ("reflection", record.text)
        }
    }

    func keep(_ text: String) -> Bool {
        let key = dedupKey(text)
        guard !key.isEmpty else { return false }
        if seen.contains(key) { return false }
        for prior in recent.suffix(24)
        where HotwordMatcher.similarity(prior, key) >= 0.9 {
            return false
        }
        seen.insert(key)
        recent.append(key)
        return true
    }

    return records.compactMap { record in
        guard let (label, text) = labelAndText(record),
              keep(text) else { return nil }
        return "\(label): \(text)"
    }.joined(separator: "\n")
}
```

- [ ] **Step 2: Replace the current deterministic `reduce` function with this version**

```swift
/// Reduce phase: the final summary, written from notes alone. The
/// deterministic renderer is used only if the model output is unusable.
func reduce(
    notes: [SessionRecord.ChunkNote],
    style: SummaryStyle = .meeting,
    length: SummaryLength = .standard,
    transcriptCharacterCount: Int? = nil,
    in language: AppLanguage,
    stitchDetails: Bool = true,
    progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
) async throws -> String {
    let sizing = Self.summaryPromptSizing(
        style: style,
        length: length,
        transcriptCharacterCount: transcriptCharacterCount
            ?? notes.reduce(0) { total, note in
                total + note.headline.count
                    + note.facts.reduce(0) { $0 + $1.count }
                    + note.decisions.reduce(0) { $0 + $1.count }
                    + note.actions.reduce(0) { $0 + $1.count }
            },
        noteCount: notes.count)
    let input = Self.reduceInput(notes: notes, style: style)
    guard !input.isEmpty else { throw SummaryError.generationFailed }
    let prompt = prompts.reduceSummaryPrompt(
        notes: input,
        style: style,
        in: language,
        sizing: sizing)
    var raw = ""
    var parsed = PromptBuilder.ParsedStructuredSummary(style: style)
    for attempt in 0..<2 {
        raw = try await llm.generate(
            system: prompt.system,
            user: prompt.user,
            maxTokens: sizing.maxTokens,
            temperature: 0.3)
        parsed = prompts.parseStructuredSummary(raw, style: style, sizing: sizing)
        if !parsed.isEmpty { break }
        if attempt == 0 { try Task.checkCancellation() }
    }

    let summary = Self.renderReducedSummary(
        raw: raw,
        parsed: parsed,
        notes: notes,
        style: style,
        length: length,
        in: language,
        stitchDetails: stitchDetails)
    guard !summary.isEmpty else { throw SummaryError.generationFailed }
    await progress?(1, 1)
    return summary
}
```

- [ ] **Step 3: Insert `renderReducedSummary` after the `reduce` function**

```swift
static func renderReducedSummary(
    raw: String,
    parsed: PromptBuilder.ParsedStructuredSummary,
    notes: [SessionRecord.ChunkNote],
    style: SummaryStyle,
    length: SummaryLength,
    in language: AppLanguage,
    stitchDetails: Bool
) -> String {
    let prompts = PromptBuilder()
    func fallback() -> String {
        SummaryRecordReducer.render(
            records: SummaryRecordReducer.records(from: notes),
            style: style,
            length: length,
            in: language,
            stitchDetails: stitchDetails)
    }

    guard !parsed.isEmpty else { return fallback() }
    let cleaned = prompts.deduplicatedStructuredSummary(parsed)
    guard !PromptBuilder.hasDegenerateRepetition(cleaned.joinedValues)
    else { return fallback() }
    let summary = prompts.renderSummaryMarkdown(cleaned, in: language)
    return summary.isEmpty ? fallback() : summary
}
```

- [ ] **Step 4: Update the `summarize(_:style:length:in:progress:)` reduce call**

Replace the existing call with:

```swift
let summary = try await reduce(
    notes: AttachmentNotes.merged(notes, attachments: record.attachments),
    style: style,
    length: length,
    transcriptCharacterCount: record.entries.reduce(0) {
        $0 + $1.sourceText.count
    },
    in: language,
    progress: { done, _ in
        progress(mappedCount + done, totalSteps)
    })
```

- [ ] **Step 5: Verify Task 3 tests pass**

Manual Xcode: run the three new `SummaryEngineTests` tests on a connected real iPhone.

Expected: the three tests pass.

- [ ] **Step 6: Compile check**

```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Loqi/Pipeline/Summary/SummaryEngine.swift LoqiTests/SummaryEngineTests.swift
git commit -m "feat: synthesize cleaner final summaries"
```

---

### Task 5: Final Verification

**Files:**
- Verify: `Loqi/Pipeline/Refinement/PromptBuilder.swift`
- Verify: `Loqi/Pipeline/Summary/SummaryEngine.swift`
- Verify: `LoqiTests/SummaryEngineTests.swift`

- [ ] **Step 1: Run focused summary tests on a real iPhone**

Manual Xcode: run all `LoqiTests/SummaryEngineTests` tests on a connected real iPhone.

Expected: all `SummaryEngineTests` pass.

- [ ] **Step 2: Run compile check**

```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Inspect the final diff**

```bash
git diff --stat main..HEAD
git diff main..HEAD -- Loqi/Pipeline/Refinement/PromptBuilder.swift Loqi/Pipeline/Summary/SummaryEngine.swift LoqiTests/SummaryEngineTests.swift
```

Expected: diff only touches the planned summary prompt, reduce, and tests files, plus the approved docs already on this branch.

- [ ] **Step 4: Commit final verification note only if any docs were adjusted**

If no docs changed during verification, skip this commit. If a doc was corrected, run:

```bash
git add docs/superpowers/specs/2026-06-20-summary-writing-design.md docs/superpowers/plans/2026-06-20-summary-writing-quality.md
git commit -m "docs: refine summary writing plan"
```
