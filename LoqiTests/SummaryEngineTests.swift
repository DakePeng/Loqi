import Foundation
import Testing
@testable import Loqi

struct SummaryEngineTests {
    /// Collects (done, total) progress reports on the main actor.
    @MainActor
    private final class ProgressBox {
        var reported: [(Int, Int)] = []
    }

    private func entry(
        _ text: String, at seconds: TimeInterval, speaker: Int? = nil
    ) -> SessionRecord.Entry {
        SessionRecord.Entry(
            sourceText: text,
            translation: nil,
            speaker: speaker,
            direction: LanguagePair(source: .chinese, target: .english),
            timestamp: Date(timeIntervalSince1970: 1_000_000 + seconds))
    }

    // MARK: Chunking

    @Test func chunksSplitOnBudget() {
        let long = String(repeating: "字", count: 400)
        let entries = (0..<6).map { entry(long, at: Double($0) * 5) }
        let chunks = SummaryEngine.chunkEntries(entries, budget: 1100)
        // 400 chars each, budget 1100 → 2 entries per chunk... third would
        // exceed (1200 > 1100), so chunks of 2.
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count == 2 })
    }

    @Test func chunksSplitOnLongPause() {
        let entries = [
            entry("第一句", at: 0),
            entry("第二句", at: 5),
            entry("第三句", at: 60),   // 55s gap → new chunk
        ]
        let chunks = SummaryEngine.chunkEntries(entries)
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 2)
        #expect(chunks[1].count == 1)
    }

    @Test func speakerChangePrefersBreakWhenChunkMostlyFull() {
        let long = String(repeating: "字", count: 700)   // > 60% of 1100
        let entries = [
            entry(long, at: 0, speaker: 0),
            entry("另一个人说话", at: 5, speaker: 1),
        ]
        let chunks = SummaryEngine.chunkEntries(entries)
        #expect(chunks.count == 2)
    }

    @Test func speakerChangeKeepsTogetherWhenChunkSmall() {
        let entries = [
            entry("短句", at: 0, speaker: 0),
            entry("回答", at: 3, speaker: 1),
        ]
        let chunks = SummaryEngine.chunkEntries(entries)
        #expect(chunks.count == 1)
    }

    // MARK: Refinement output parsing (translation only — source rewriting
    // was removed; an "S:" line from an old prompt shape is ignored)

    @Test func taggedTranslationParses() {
        let parsed = PromptBuilder().parseRefinement(
            "S: 我觉得要不就英法都考一下\nT: I think we should test both English and French.")
        #expect(parsed == "I think we should test both English and French.")
    }

    @Test func untaggedOutputIsTheTranslation() {
        let parsed = PromptBuilder().parseRefinement("こんにちは、お元気ですか。")
        #expect(parsed == "こんにちは、お元気ですか。")
    }

    // MARK: Hotword-restore parsing + fidelity gate

    @Test func restoredSentenceParsesTaggedAndUntagged() {
        #expect(PromptBuilder().parseRestoredSentence("S: 我们和志鹏开会")
            == "我们和志鹏开会")
        #expect(PromptBuilder().parseRestoredSentence("我们和志鹏开会")
            == "我们和志鹏开会")
    }

    @Test func acceptsTermSwap() {
        let original = "我觉要不就英法问一下考两个来现"
        let restored = "我觉得要不就英法都问一下，考两个来"
        #expect(PromptBuilder().isAcceptableHotwordRestore(restored, original: original))
    }

    @Test func rejectsMeaningDivergentRewrite() {
        let original = "我觉要不就英法问一下考两个来现"
        let restored = "今天天气很好我们去公园散步吧"
        #expect(!PromptBuilder().isAcceptableHotwordRestore(restored, original: original))
    }

    @Test func rejectsLengthExplosion() {
        let original = "短句"
        let restored = String(repeating: "解释一下这个短句的意思", count: 5)
        #expect(!PromptBuilder().isAcceptableHotwordRestore(restored, original: original))
    }

    // MARK: Summary records

    @Test func chunkRecordPromptSeparatesContextFromTarget() {
        let prompt = PromptBuilder().chunkRecordPrompt(
            chunkID: "c003",
            timeRange: "04:00-06:00",
            contextOnly: "m000\tEarlier overlap",
            target: "m031\t小模型直接做开放式总结时容易产生幻觉",
            vocabulary: ["Loqi (product name)"],
            in: .chinese)

        #expect(prompt.system.contains("context_only"))
        #expect(prompt.system.contains("target"))
        #expect(prompt.system.contains("forbidden") || prompt.system.contains("禁止"))
        #expect(prompt.system.contains("TSV"))
        // A3: rationale/qualifier clauses are preserved, not stripped.
        #expect(prompt.system.contains("qualifier"))
        #expect(prompt.user.contains("chunk_id: c003"))
        #expect(prompt.user.contains("context_only:"))
        #expect(prompt.user.contains("target:"))
        #expect(prompt.user.contains("Known terms: Loqi (product name)"))
    }

    @Test func cleanMapInputCollapsesStutters() {
        #expect(SummaryEngine.cleanMapInput("有有有没有") == "有没有")
        #expect(SummaryEngine.cleanMapInput("预算定为42万") == "预算定为42万")
    }

    @Test func debugLogsDoNotExposeTranscriptText() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appending(path: "Loqi/Pipeline/Summary/SummaryEngine.swift"),
            encoding: .utf8)

        #expect(!text.contains("Temporary diagnostic"))
        #expect(!text.contains("note.headline, privacy: .public"))
    }

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
        #expect(prompt.system.contains("most important"))
        // B2: photos must not be spun into invented to-dos/decisions.
        #expect(prompt.system.contains("Photos are reference context only"))
        #expect(prompt.system.contains("never turn a photo into"))
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

    @Test func structuredSummaryCleanupDropsRepeatedOverviewLines() {
        var parsed = PromptBuilder.ParsedStructuredSummary(style: .meeting)
        parsed.overview = [
            "会议讨论六月发布计划。",
            "会议讨论六月发布计划",
        ]

        let cleaned = PromptBuilder().deduplicatedStructuredSummary(parsed)

        #expect(cleaned.overview == ["会议讨论六月发布计划。"])
    }

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

    @Test func reduceInputDoesNotLetTopicDropSameTextDecision() {
        let note = SessionRecord.ChunkNote(
            headline: "预算定为 42 万",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            decisions: ["预算定为 42 万"])

        let input = SummaryEngine.reduceInput(notes: [note], style: .meeting)

        #expect(input.contains("topic: 预算定为 42 万"))
        #expect(input.contains("decision: 预算定为 42 万"))
    }

    @Test func reduceInputIncludesTopicSummaryWhenTitleExists() {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let note = SessionRecord.ChunkNote(
            headline: "预算",
            startedAt: timestamp,
            summaryRecords: [
                .init(
                    kind: .topic,
                    source: .transcript,
                    sourceIDs: ["m001"],
                    sourceIndex: 0,
                    timestamp: timestamp,
                    text: "预算定为 42 万，并且六月发布前完成验收",
                    topicTitle: "预算")
            ])

        let input = SummaryEngine.reduceInput(notes: [note], style: .meeting)

        #expect(input.contains("topic: 预算定为 42 万，并且六月发布前完成验收"))
    }

    @Test func reduceInputCanBeBoundForLongSessions() {
        let notes = (0..<80).map { index in
            SessionRecord.ChunkNote(
                headline: "第 \(index) 段",
                startedAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)),
                facts: ["记录第 \(index) 段里的关键事实"],
                decisions: ["决定第 \(index) 段的处理方式"],
                actions: index == 42 ? ["负责人处理稀疏待办"] : [])
        }

        // The unbounded input dedups near-identical sequential notes, so its
        // last surviving line is the tail the bound must still preserve.
        let lastLine = SummaryEngine.reduceInput(notes: notes, style: .meeting)
            .split(separator: "\n").last.map(String.init)

        let input = SummaryEngine.reduceInput(
            notes: notes, style: .meeting, maxCharacters: 180)

        #expect(!input.isEmpty)
        #expect(input.count <= 180)
        #expect(input.split(separator: "\n").allSatisfy { $0.contains(": ") })
        // The rare action and the session's tail both survive the bound.
        #expect(input.contains("action: 负责人处理稀疏待办"))
        #expect(lastLine.map(input.contains) == true)
    }

    @Test func hasSpokenSubstanceDistinguishesPhotoOnlyNotes() {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        func record(
            kind: SessionRecord.SummaryRecord.Kind,
            source: SessionRecord.SummaryRecord.Source,
            text: String
        ) -> SessionRecord.SummaryRecord {
            .init(
                kind: kind, source: source, sourceIDs: ["x"],
                sourceIndex: 0, timestamp: timestamp, text: text)
        }

        // A spoken non-topic record is real substance.
        #expect(SummaryEngine.hasSpokenSubstance(
            [record(kind: .decision, source: .transcript, text: "六月发布")]))
        // A photo point alone is not — it would seed invented to-dos.
        #expect(!SummaryEngine.hasSpokenSubstance(
            [record(kind: .point, source: .photo, text: "这是一张展示马的插画设计图")]))
        // A bare topic headline alone is not substance either.
        #expect(!SummaryEngine.hasSpokenSubstance(
            [record(kind: .topic, source: .transcript, text: "应该是在的")]))
    }

    @Test func reducePhotoOnlyNotesDoesNotFabricateToDos() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let photo = SessionRecord.Attachment(
            fileName: "horse.jpg",
            timestamp: timestamp,
            vlmDescription: "这是一张展示马的插画设计图。")
        let notes = AttachmentNotes.merged([], attachments: [photo])
        // A model that would happily hallucinate is never consulted: the
        // photo-only guard renders deterministically.
        let missingModel = ModelOption(
            id: "loqi-tests/missing-model",
            displayName: "Missing test model",
            requiredHeadroom: 1,
            downloadBytes: 1)
        let engine = SummaryEngine(llm: LLMService(model: missingModel))

        let summary = try await engine.reduce(
            notes: notes,
            style: .memo,
            length: .detailed,
            in: .chinese)

        #expect(summary.contains("马的插画设计图"))
        // No invented to-do / next-step section appears.
        #expect(!summary.contains("## 待办事项"))
    }

    @Test func fallbackStubNotesContributeNoTopicRecord() {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let stub = SessionRecord.ChunkNote(
            headline: "应该是在的",          // raw opening words of a garbled chunk
            startedAt: timestamp,
            isFallback: true)
        let real = SessionRecord.ChunkNote(
            headline: "预算讨论",
            startedAt: timestamp,
            decisions: ["六月发布"])

        #expect(SummaryRecordReducer.records(from: stub).isEmpty)
        #expect(SummaryRecordReducer.records(from: real).contains { $0.kind == .topic })
    }

    @Test func reduceFallsBackWhenGenerationThrows() async throws {
        let note = SessionRecord.ChunkNote(
            headline: "桌布讨论",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            facts: ["传家宝桌子不必铺布"])
        let missingModel = ModelOption(
            id: "loqi-tests/missing-model",
            displayName: "Missing test model",
            requiredHeadroom: 1,
            downloadBytes: 1)
        let engine = SummaryEngine(llm: LLMService(model: missingModel))

        let summary = try await engine.reduce(
            notes: [note],
            style: .meeting,
            length: .standard,
            in: .chinese)

        #expect(summary.contains("传家宝桌子不必铺布"))
    }

    /// Progress must stay on the original run's scale across a resume:
    /// cached chunks count as completed steps, so the UI never restarts
    /// at 0/remaining after backgrounding (reads as "all progress lost").
    @Test @MainActor func resumeProgressCountsCachedChunksAsDone() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let entry = SessionRecord.Entry(
            sourceText: "预算定为 42 万",
            translation: nil,
            speaker: nil,
            direction: LanguagePair(source: .chinese, target: .chinese),
            timestamp: timestamp)
        var record = SessionRecord(
            mode: .captions,
            startedAt: timestamp,
            endedAt: timestamp,
            entries: [entry])
        record.chunkNotes = [.init(
            headline: "预算",
            startedAt: timestamp,
            anchorEntryID: entry.id,
            facts: ["预算定为 42 万"])]
        record.liveNotesEndEntryID = entry.id
        let missingModel = ModelOption(
            id: "loqi-tests/missing-model",
            displayName: "Missing test model",
            requiredHeadroom: 1,
            downloadBytes: 1)
        let engine = SummaryEngine(llm: LLMService(model: missingModel))

        let box = ProgressBox()
        _ = try await engine.summarize(
            record,
            style: .meeting,
            length: .standard,
            in: .chinese,
            progress: { done, total in box.reported.append((done, total)) })

        // One cached chunk + the reduce step: every report sits at or past
        // the cached work, on the full-scale total — never 0/remaining.
        #expect(!box.reported.isEmpty)
        #expect(box.reported.allSatisfy { $0.0 >= 1 && $0.1 == 2 })
    }

    @Test func summarizeWithFullCachedNotesFallsBackWithoutLoadingModel() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let entry = SessionRecord.Entry(
            sourceText: "预算定为 42 万",
            translation: nil,
            speaker: nil,
            direction: LanguagePair(source: .chinese, target: .chinese),
            timestamp: timestamp)
        var record = SessionRecord(
            mode: .captions,
            startedAt: timestamp,
            endedAt: timestamp,
            entries: [entry])
        record.chunkNotes = [.init(
            headline: "预算",
            startedAt: timestamp,
            anchorEntryID: entry.id,
            facts: ["预算定为 42 万"])]
        record.liveNotesEndEntryID = entry.id
        let missingModel = ModelOption(
            id: "loqi-tests/missing-model",
            displayName: "Missing test model",
            requiredHeadroom: 1,
            downloadBytes: 1)
        let engine = SummaryEngine(llm: LLMService(model: missingModel))

        let result = try await engine.summarize(
            record,
            style: .meeting,
            length: .standard,
            in: .chinese,
            progress: { _, _ in })

        #expect(result.summary.contains("预算定为 42 万"))
        #expect(result.notes.map(\.headline) == ["预算"])
    }

    @Test func reduceFallsBackWhenStructuredInputIsEmptyButDetailsCanRender() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let note = SessionRecord.ChunkNote(
            headline: "术语",
            startedAt: timestamp,
            summaryRecords: [
                .init(
                    kind: .term,
                    source: .transcript,
                    sourceIDs: ["m001"],
                    sourceIndex: 0,
                    timestamp: timestamp,
                    text: "Loqi 是本地转写工具")
            ])
        let missingModel = ModelOption(
            id: "loqi-tests/missing-model",
            displayName: "Missing test model",
            requiredHeadroom: 1,
            downloadBytes: 1)
        let engine = SummaryEngine(llm: LLMService(model: missingModel))

        let summary = try await engine.reduce(
            notes: [note],
            style: .meeting,
            length: .detailed,
            in: .english)

        #expect(summary.contains("## Details"))
        #expect(summary.contains("Loqi 是本地转写工具"))
    }

    @Test func reduceWithoutStitchedDetailsDoesNotWaitForLLM() async throws {
        let llm = LLMService()
        await llm.setBackgrounded(true)
        let engine = SummaryEngine(llm: llm)
        let note = SessionRecord.ChunkNote(
            headline: "现场摘要",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            facts: ["录音中查看摘要不应占用模型"])

        let didRender = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let summary = try await engine.reduce(
                        notes: [note],
                        style: .meeting,
                        length: .standard,
                        in: .chinese,
                        stitchDetails: false)
                    return summary.contains("录音中查看摘要不应占用模型")
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(50))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await llm.setBackgrounded(false)

        #expect(didRender)
    }

    @Test func structuredReduceGenerationFallsBackAfterOneThrow() async throws {
        var attempts = 0

        let output = try await SummaryEngine.generateStructuredReduce(style: .meeting) {
            attempts += 1
            throw LLMServiceError.modelNotLoaded
        } parse: { _ in
            var parsed = PromptBuilder.ParsedStructuredSummary(style: .meeting)
            parsed.overview = ["不应解析"]
            return parsed
        }

        #expect(attempts == 1)
        #expect(output.raw.isEmpty)
        #expect(output.parsed.isEmpty)
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

    @Test func reducedSummaryStitchesMissingPopulatedSection() {
        var parsed = PromptBuilder.ParsedStructuredSummary(style: .meeting)
        parsed.overview = ["会议讨论发布安排。"]
        let note = SessionRecord.ChunkNote(
            headline: "发布计划",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            facts: ["需要同步发布材料"],
            decisions: ["六月发布"],
            actions: ["王经理确认供应商"])

        let summary = SummaryEngine.renderReducedSummary(
            raw: "",
            parsed: parsed,
            notes: [note],
            style: .meeting,
            length: .standard,
            in: .chinese,
            stitchDetails: true)

        // Synthesized overview survives — the whole summary is no longer
        // discarded just because the model dropped the populated sections.
        #expect(summary.contains("会议讨论发布安排。"))
        // The dropped sections are stitched back in deterministically.
        #expect(summary.contains("## 决定"))
        #expect(summary.contains("六月发布"))
        #expect(summary.contains("## 待办事项"))
    }

    @Test func reducedSummaryFallsBackWhenOnlyDecisionRecordIsOmitted() {
        var parsed = PromptBuilder.ParsedStructuredSummary(style: .meeting)
        parsed.overview = ["会议讨论发布安排。"]
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let note = SessionRecord.ChunkNote(
            headline: "发布计划",
            startedAt: timestamp,
            summaryRecords: [
                .init(
                    kind: .decision,
                    source: .transcript,
                    sourceIDs: ["m001"],
                    sourceIndex: 0,
                    timestamp: timestamp,
                    text: "六月发布")
            ])

        let summary = SummaryEngine.renderReducedSummary(
            raw: "",
            parsed: parsed,
            notes: [note],
            style: .meeting,
            length: .standard,
            in: .chinese,
            stitchDetails: true)

        #expect(summary.contains("六月发布"))
    }

    @Test func reducedDetailedSummaryStitchesDeterministicDetails() {
        var parsed = PromptBuilder.ParsedStructuredSummary(style: .meeting)
        parsed.overview = ["会议讨论预算和六月发布安排。"]
        parsed.sections[0] = ["预算是 42 万"]
        let note = SessionRecord.ChunkNote(
            headline: "发布计划",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            facts: ["预算是 42 万", "团队需要在六月发布前完成验收"],
            decisions: ["六月发布"])

        let detailed = SummaryEngine.renderReducedSummary(
            raw: "",
            parsed: parsed,
            notes: [note],
            style: .meeting,
            length: .detailed,
            in: .chinese,
            stitchDetails: true)
        let compact = SummaryEngine.renderReducedSummary(
            raw: "",
            parsed: parsed,
            notes: [note],
            style: .meeting,
            length: .detailed,
            in: .chinese,
            stitchDetails: false)

        #expect(detailed.contains("## 详细记录"))
        #expect(detailed.contains("- 团队需要在六月发布前完成验收"))
        #expect(!compact.contains("## 详细记录"))
    }

    @Test func parsesSummaryRecordTSVAndRejectsInvalidLines() {
        // The c999 line is ACCEPTED: only one chunk exists per call, so a
        // mis-stamped c-id still marks a record from this chunk (device
        // logs showed real records discarded over borrowed ids). Grounding
        // stays enforced — the m999 and short A lines are rejected.
        let raw = """
        T	c003	04:00-06:00	摘要去重	讨论本地摘要中的幻觉和重复
        P	c003	m031,m032	小模型开放式总结容易产生幻觉
        D	c003	m033	最终阶段不再使用模型合并
        A	c003	m034	王经理	设计字符串拼接流程	周五
        Q	c003	m035	如何减少 overlap 重复
        R	c003	m036	最终合并会引入新幻觉
        P	c999	m031	借用错误 chunk id 仍被接受
        P	c003	m999	错误 source 被丢弃
        A	c003	m034	字段不够
        """

        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c003",
            validSourceIDs: ["m031", "m032", "m033", "m034", "m035", "m036"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000))

        #expect(records.map(\.kind) == [
            .topic, .point, .decision, .action, .question, .risk, .point,
        ])
        #expect(records[0].topicTitle == "摘要去重")
        #expect(records[0].timeRange == "04:00-06:00")
        #expect(records[1].sourceIDs == ["m031", "m032"])
        #expect(records[3].owner == "王经理")
        #expect(records[3].deadline == "周五")
        #expect(records[6].text == "借用错误 chunk id 仍被接受")
    }

    /// A `chunk_id` placeholder echo used to reject every line and stub
    /// the whole chunk; the records are still from this call's target.
    @Test func parserAcceptsPlaceholderChunkIDEcho() {
        var diagnostics = PromptBuilder.ParseDiagnostics()
        let records = PromptBuilder().parseSummaryRecords(
            "P\tchunk_id\tm001\t定价方案下周敲定",
            chunkID: "c002",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            diagnostics: &diagnostics)
        #expect(records.map(\.text) == ["定价方案下周敲定"])
        #expect(diagnostics.accepted == 1)
    }

    /// If the model copies the prompt's example lines verbatim, their
    /// distinctive content strings must keep them out of the records —
    /// in every example language (the c000 id alone no longer rejects,
    /// since real records borrow it too).
    @Test func chunkRecordExampleEchoCannotLeakIntoRecords() {
        for language in AppLanguage.allCases {
            var diagnostics = PromptBuilder.ParseDiagnostics()
            let records = PromptBuilder().parseSummaryRecords(
                PromptBuilder.chunkRecordExample(in: language),
                chunkID: "c002",
                validSourceIDs: ["m001", "m002", "m003"],
                source: .transcript,
                timestamp: Date(timeIntervalSince1970: 1_000_000),
                diagnostics: &diagnostics)
            #expect(records.isEmpty)
            #expect(diagnostics.exampleEcho == 6)
        }
    }

    /// A real record stamped with the example's c000 id is kept — the
    /// device failure mode where idMiss discarded well-formed records.
    @Test func parserAcceptsBorrowedExampleChunkID() {
        let records = PromptBuilder().parseSummaryRecords(
            "P\tc000\tm001\t下季度重点是本地化",
            chunkID: "c002",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000))
        #expect(records.map(\.text) == ["下季度重点是本地化"])
    }

    /// The tolerant chunk-id match must not admit the model echoing the
    /// spec block itself — placeholder words where content belongs.
    @Test func parserRejectsVerbatimSpecEcho() {
        var diagnostics = PromptBuilder.ParseDiagnostics()
        let raw = """
        T\tchunk_id\ttime_range\ttopic_title\tone_line_summary
        P\tchunk_id\tsource_ids\tkey_point
        A\tchunk_id\tsource_ids\towner\ttask\tdeadline
        """
        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c002",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            diagnostics: &diagnostics)
        #expect(records.isEmpty)
        #expect(diagnostics.specEcho == 3)
    }

    /// A completely tab-less response (spaces-for-tabs models) parses via
    /// the 2+-whitespace fallback; single spaces stay inside fields.
    @Test func parserFallsBackToSpacesWhenResponseHasNoTabs() {
        var diagnostics = PromptBuilder.ParseDiagnostics()
        let raw = """
        T  c002  00:00-02:00  预算  讨论预算方案和 42 万的分配
        P  c002  m001  定价方案下周敲定
        """
        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c002",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            diagnostics: &diagnostics)
        #expect(!diagnostics.hadTabs)
        #expect(records.map(\.kind) == [.topic, .point])
        #expect(records[1].text == "定价方案下周敲定")
    }

    /// The device regression behind columns=8/8: one response mixing
    /// properly tabbed lines with space-separated ones. The split must
    /// adapt per line, not per response.
    @Test func parserHandlesMixedTabAndSpaceLines() {
        var diagnostics = PromptBuilder.ParseDiagnostics()
        let raw = """
        T\tc002\t00:00-02:00\t预算\t讨论预算方案
        P  c002  m001  定价方案下周敲定
        D c002 m001 使用本地模型
        """
        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c002",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            diagnostics: &diagnostics)
        #expect(records.map(\.kind) == [.topic, .point, .decision])
        #expect(records[1].text == "定价方案下周敲定")
        #expect(records[2].text == "使用本地模型")
    }

    /// m-id citations the model copies into content fields are scrubbed —
    /// users never see source ids (the device screenshot bug: "m004-007
    /// 价格：80元/斤" bullets and ids paraphrased into the overview).
    @Test func sourceIDTokensAreScrubbedFromContent() {
        #expect(PromptBuilder.strippedSourceIDTokens(
            "m004-007 价格：80 元/斤（杨梅）。") == "价格：80 元/斤（杨梅）。")
        #expect(PromptBuilder.strippedSourceIDTokens(
            "m005,m006 要求：加一个、再加一个。") == "要求：加一个、再加一个。")
        #expect(PromptBuilder.strippedSourceIDTokens(
            "是否要点个特色菜?（m005 提及杨梅）") == "是否要点个特色菜?（提及杨梅）")
        #expect(PromptBuilder.strippedSourceIDTokens(
            "其中m004-007价格 80 元/斤") == "其中价格 80 元/斤")
        // Id-only content scrubs to empty (record then drops out).
        #expect(PromptBuilder.strippedSourceIDTokens("m005").isEmpty)
        // Clean prose and lookalike words survive.
        #expect(PromptBuilder.strippedSourceIDTokens(
            "预算定为 42 万") == "预算定为 42 万")
        #expect(PromptBuilder.strippedSourceIDTokens(
            "team004 shipped a small fix") == "team004 shipped a small fix")
    }

    /// End to end: a record line whose text field carries copied ids
    /// parses with clean text.
    @Test func parsedRecordTextHasNoSourceIDTokens() {
        let records = PromptBuilder().parseSummaryRecords(
            "P\tc001\tm004\tm004-007 价格：80 元/斤",
            chunkID: "c001",
            validSourceIDs: ["m004"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000))
        #expect(records.map(\.text) == ["价格：80 元/斤"])
        #expect(records[0].sourceIDs == ["m004"])
    }

    /// The compressed-schema device failure (colsSeen=["T:4","P:3","A:4"]):
    /// when strict parsing accepts nothing, the salvage pass re-reads the
    /// near-miss shapes instead of stubbing the whole chunk.
    @Test func parserSalvagesCompressedSchemaWhenStrictParseIsEmpty() {
        var diagnostics = PromptBuilder.ParseDiagnostics()
        let raw = """
        T\tc001\t预算讨论\t确定预算方向和上限
        P\tc001\t上限是 45 万
        A\tc001\t老张\t整理预算表
        """
        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c001",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            diagnostics: &diagnostics)
        #expect(diagnostics.salvaged == 3)
        #expect(records.map(\.kind) == [.topic, .point, .action])
        #expect(records[0].topicTitle == "预算讨论")
        #expect(records[0].timeRange == "")
        // Uncited salvage stays visibly ungrounded.
        #expect(records[1].sourceIDs.isEmpty)
        #expect(records[1].text == "上限是 45 万")
        #expect(records[2].owner == "老张")
        #expect(records[2].task == "整理预算表")
    }

    /// A T:4 line whose third field is time-like keeps the range and
    /// reuses the merged remainder as title and summary; an A:4 whose
    /// third field cites valid ids keeps the citation.
    @Test func parserSalvageResolvesAmbiguousFields() {
        var diagnostics = PromptBuilder.ParseDiagnostics()
        let raw = """
        T\tc001\t00:00-02:00\t确定预算方向
        A\tc001\tm001\t整理预算表
        """
        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c001",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            diagnostics: &diagnostics)
        #expect(records[0].timeRange == "00:00-02:00")
        #expect(records[0].topicTitle == "确定预算方向")
        #expect(records[1].sourceIDs == ["m001"])
        #expect(records[1].owner == "未明确")
    }

    /// Mid-response the model omits the chunk-id column and leads with
    /// citations ("P\tm004\t…"). The valid-source-id check proves the
    /// interpretation, so these salvage with full grounding; an invalid
    /// citation (m999) still dies.
    @Test func parserSalvagesIdLedLines() {
        var diagnostics = PromptBuilder.ParseDiagnostics()
        let raw = """
        P\tm004\t价格是 80 元一斤
        Q\tm005\t是否要点特色菜
        A\tm006\t老张\t确认加菜数量
        P\tm999\t无效引用不得进入
        """
        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c002",
            validSourceIDs: ["m004", "m005", "m006"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            diagnostics: &diagnostics)
        #expect(records.map(\.kind) == [.point, .question, .action])
        #expect(records[0].sourceIDs == ["m004"])
        #expect(records[0].text == "价格是 80 元一斤")
        #expect(records[2].owner == "老张")
        #expect(records[2].task == "确认加菜数量")
        #expect(diagnostics.salvaged == 3)
        #expect(!records.contains { $0.text.contains("无效引用") })
    }

    /// Salvage never runs when strict parsing produced anything — a
    /// compliant response keeps full strictness for its malformed lines.
    @Test func parserSkipsSalvageWhenStrictParseSucceeded() {
        var diagnostics = PromptBuilder.ParseDiagnostics()
        let raw = """
        P\tc001\tm001\t完整的合规记录
        P\tc001\t缺少引用的记录
        """
        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c001",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            diagnostics: &diagnostics)
        #expect(records.map(\.text) == ["完整的合规记录"])
        #expect(diagnostics.salvaged == 0)
        #expect(diagnostics.columnCount == 1)
    }

    /// A trailing tab must not fail the column count.
    @Test func parserToleratesTrailingTab() {
        let records = PromptBuilder().parseSummaryRecords(
            "P\tc002\tm001\t定价方案下周敲定\t",
            chunkID: "c002",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000))
        #expect(records.map(\.text) == ["定价方案下周敲定"])
    }

    @Test func parserDiagnosticsTallyRejectionReasons() {
        var diagnostics = PromptBuilder.ParseDiagnostics()
        // The A line has 3 fields — below even the salvage shape (A:4) —
        // and the P lines are strict-shaped (rejected for cause), so
        // nothing here is salvageable and the tallies stay pure.
        let raw = """
        P\tx9\tm001\t无效 id 被丢弃
        P\tc003\tm999\t错误 source 被丢弃
        A\tc003\t字段不够
        X\tc003\tm001\t未知标签
        """
        let records = PromptBuilder().parseSummaryRecords(
            raw,
            chunkID: "c003",
            validSourceIDs: ["m001"],
            source: .transcript,
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            diagnostics: &diagnostics)
        #expect(records.isEmpty)
        #expect(diagnostics.lines == 4)
        #expect(diagnostics.chunkIDMismatch == 1)
        #expect(diagnostics.invalidSourceIDs == 1)
        #expect(diagnostics.columnCount == 1)
        #expect(diagnostics.unknownTag == 1)
        #expect(diagnostics.accepted == 0)
    }

    /// A model that can't load is a job failure, not a format miss — it
    /// must propagate instead of degrading the chunk to a stub.
    @Test func makeNotesPropagatesModelUnavailability() async {
        let missingModel = ModelOption(
            id: "loqi-tests/missing-model",
            displayName: "Missing test model",
            requiredHeadroom: 1,
            downloadBytes: 1)
        let engine = SummaryEngine(llm: LLMService(model: missingModel))
        await #expect(throws: LLMServiceError.self) {
            _ = try await engine.makeNotes(
                for: [self.entry("预算定为 42 万", at: 0)],
                speakerLabel: { _ in nil },
                fallbackDate: Date(timeIntervalSince1970: 1_000_000),
                in: .chinese,
                progress: { _, _ in })
        }
    }

    @Test func deterministicRendererDedupesAndLabelsPhotoOnlyRecords() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(SummaryEngine.dedupKey("讨论六月发布计划") == "讨论六月发布计划")
        let records: [SessionRecord.SummaryRecord] = [
            .init(
                kind: .topic,
                source: .transcript,
                sourceIDs: ["m001"],
                sourceIndex: 0,
                timestamp: t0,
                text: "讨论六月发布计划",
                topicTitle: "发布计划",
                timeRange: "00:00-02:00"),
            .init(
                kind: .point,
                source: .transcript,
                sourceIDs: ["m002"],
                sourceIndex: 1,
                timestamp: t0.addingTimeInterval(5),
                text: "预算是 42 万"),
            .init(
                kind: .point,
                source: .transcript,
                sourceIDs: ["m003"],
                sourceIndex: 2,
                timestamp: t0.addingTimeInterval(10),
                text: "预算是42万"),
            .init(
                kind: .point,
                source: .photo,
                sourceIDs: ["p001"],
                sourceIndex: 3,
                timestamp: t0.addingTimeInterval(20),
                text: "白板写着六月发布",
                sourceLabel: "Photo 10:24"),
        ]

        let summary = SummaryRecordReducer.render(
            records: records,
            style: .meeting,
            length: .standard,
            in: .chinese,
            stitchDetails: false)

        #expect(summary.contains("讨论六月发布计划"))
        #expect(summary.contains("预算是 42 万"))
        #expect(!summary.contains("预算是42万"))
        #expect(summary.contains("[Photo 10:24] 白板写着六月发布"))
    }

    @Test func rendererDoesNotRepeatSameContentAcrossSections() {
        let text = "测试录音中手机语言识别"
        let records: [SessionRecord.SummaryRecord] = [
            .init(
                kind: .topic,
                source: .transcript,
                sourceIDs: ["m001"],
                sourceIndex: 0,
                timestamp: Date(timeIntervalSince1970: 1_000_000),
                text: text,
                topicTitle: text,
                timeRange: "00:00-00:05"),
            .init(
                kind: .point,
                source: .transcript,
                sourceIDs: ["m001"],
                sourceIndex: 1,
                timestamp: Date(timeIntervalSince1970: 1_000_001),
                text: text),
        ]

        let summary = SummaryRecordReducer.render(
            records: records,
            style: .memo,
            length: .detailed,
            in: .chinese)

        #expect(summary.components(separatedBy: text).count - 1 == 1)
    }

    @Test func legacyChunkNotesConvertToRecords() {
        let note = SessionRecord.ChunkNote(
            headline: "预算讨论",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            facts: ["预算是 42 万"],
            decisions: ["六月发布"],
            actions: ["王经理确认供应商"],
            terms: ["Loqi"])

        let records = SummaryRecordReducer.records(from: [note])

        #expect(records.map(\.kind) == [
            .topic, .point, .decision, .action, .term,
        ])
        #expect(records.first?.text == "预算讨论")
        #expect(records[1].text == "预算是 42 万")
    }

    @Test func crossKindDedupKeepsMoreSpecificClassification() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let records: [SessionRecord.SummaryRecord] = [
            .init(
                kind: .topic, source: .transcript, sourceIDs: ["m001"],
                sourceIndex: 0, timestamp: t0, text: "发布计划讨论",
                topicTitle: "发布计划"),
            .init(
                kind: .point, source: .transcript, sourceIDs: ["m002"],
                sourceIndex: 1, timestamp: t0.addingTimeInterval(5),
                text: "六月发布"),
            .init(
                kind: .decision, source: .transcript, sourceIDs: ["m003"],
                sourceIndex: 2, timestamp: t0.addingTimeInterval(10),
                text: "六月发布"),
        ]

        let summary = SummaryRecordReducer.render(
            records: records, style: .meeting, length: .standard,
            in: .chinese, stitchDetails: false)

        // Point and decision share text → one bullet, classified as the
        // decision (more specific), so it renders once as a section bullet
        // instead of appearing in both the Topics and Decisions sections.
        #expect(summary.components(separatedBy: "六月发布").count - 1 == 1)
        #expect(summary.contains("- 六月发布"))
    }

    @Test func renderKeepsSameTaskActionsForDifferentOwners() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let records: [SessionRecord.SummaryRecord] = [
            .init(
                kind: .action,
                source: .transcript,
                sourceIDs: ["m001"],
                sourceIndex: 0,
                timestamp: t0,
                text: "review the launch notes",
                owner: "Alice",
                task: "review the launch notes",
                deadline: "Friday"),
            .init(
                kind: .action,
                source: .transcript,
                sourceIDs: ["m002"],
                sourceIndex: 1,
                timestamp: t0.addingTimeInterval(1),
                text: "review the launch notes",
                owner: "Bob",
                task: "review the launch notes",
                deadline: "Monday"),
        ]

        let summary = SummaryRecordReducer.render(
            records: records,
            style: .meeting,
            length: .standard,
            in: .english)

        #expect(summary.contains("Alice: review the launch notes (Friday)"))
        #expect(summary.contains("Bob: review the launch notes (Monday)"))
    }
}

