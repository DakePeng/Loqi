import Foundation
import Testing
@testable import Loqi

struct SessionRecordTests {
    private func makeRecord() -> SessionRecord {
        SessionRecord(
            mode: .captions,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_125),
            entries: [
                .init(
                    sourceText: "大家好",
                    translation: "Hello everyone",
                    speaker: 0,
                    direction: LanguagePair(source: .chinese, target: .english),
                    timestamp: .now),
                .init(
                    sourceText: "今天讲翻译",
                    translation: "Today we discuss translation",
                    speaker: 0,
                    direction: LanguagePair(source: .chinese, target: .english),
                    timestamp: .now),
                .init(
                    sourceText: "有问题吗",
                    translation: "Any questions?",
                    speaker: 1,
                    direction: LanguagePair(source: .chinese, target: .english),
                    timestamp: .now),
            ],
            speakerNames: [0: "王老师"])
    }

    @Test func titleFallsBackThroughTextThenHeadlineThenTranscript() {
        var record = makeRecord()
        #expect(record.title == "大家好")  // transcript prefix
        record.chunkNotes = [.init(headline: "课程介绍", startedAt: .now)]
        #expect(record.title == "课程介绍")  // first note headline
        record.titleText = "翻译课第一讲"
        #expect(record.title == "翻译课第一讲")  // explicit title wins
    }

    @Test func markdownContainsSpeakersAndBothLanguages() {
        let record = makeRecord()
        let md = record.markdown()
        #expect(md.contains("**王老师**"))          // custom name
        // The default label is localized ("Speaker 2" / "说话人 2"), so
        // assert against the same source of truth, not a literal.
        #expect(md.contains("**\(record.speakerLabel(1)!)**"))
        #expect(md.contains("> 大家好"))
        #expect(md.contains("> Hello everyone"))
        #expect(md.contains("## Transcript"))
    }

    /// New optional fields must never break decoding of records written
    /// by earlier app versions (their JSON lacks the keys entirely).
    @Test func legacyRecordsDecodeWithoutNewFields() throws {
        let record = makeRecord()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("unseen"))
        #expect(!json.contains("importing"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionRecord.self, from: data)
        #expect(decoded.unseen == nil)
        #expect(decoded.importing == nil)
    }

    @Test func markdownIncludesSummaryWhenPresent() {
        var record = makeRecord()
        record.summary = "A lecture about translation."
        let md = record.markdown()
        #expect(md.contains("## Summary"))
        #expect(md.contains("A lecture about translation."))
    }

    @Test func markdownDemotesSummarySectionHeadings() {
        var record = makeRecord()
        record.summary = "Overview here.\n\n## Topics\n- one\n\n## Action Items\n- two"
        record.chunkNotes = [
            .init(headline: "Intro", startedAt: .now),
            .init(headline: "Q&A", startedAt: .now),
        ]
        let md = record.markdown()
        #expect(md.contains("### Topics"))
        #expect(md.contains("### Action Items"))
        #expect(!md.contains("\n## Topics"))
        #expect(md.contains("## Timeline"))
        #expect(!md.contains("## Outline"))
    }

    @Test func decodesRecordWithoutSummaryEditedFlag() throws {
        // Files written before the flag existed must keep loading.
        let record = makeRecord()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(record))
        #expect(decoded.summaryEdited == nil)

        var edited = record
        edited.summaryEdited = true
        let roundTripped = try decoder.decode(
            SessionRecord.self, from: encoder.encode(edited))
        #expect(roundTripped.summaryEdited == true)
    }

    @Test func decodesRecordWithoutSummaryStyle() throws {
        // Files written before styles existed must keep loading and
        // resolve to the legacy meeting behavior.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(makeRecord()))
        #expect(decoded.summaryStyle == nil)
        #expect(decoded.resolvedSummaryStyle == .meeting)

        // An unknown raw value (from a future app version) must never
        // fail decoding — it degrades to meeting.
        var future = makeRecord()
        future.summaryStyle = "futureStyle"
        let degraded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(future))
        #expect(degraded.summaryStyle == "futureStyle")
        #expect(degraded.resolvedSummaryStyle == .meeting)
    }

    @Test func summaryStyleRoundTrips() throws {
        var record = makeRecord()
        record.summaryStyle = SummaryStyle.lecture.rawValue
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(record))
        #expect(decoded.resolvedSummaryStyle == .lecture)
    }

    @Test func decodesRecordWithoutSummaryLength() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(makeRecord()))
        #expect(decoded.summaryLength == nil)
        #expect(decoded.resolvedSummaryLength == .standard)

        var future = makeRecord()
        future.summaryLength = "futureLength"
        let degraded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(future))
        #expect(degraded.summaryLength == "futureLength")
        #expect(degraded.resolvedSummaryLength == .standard)
    }

    @Test func summaryLengthRoundTrips() throws {
        var record = makeRecord()
        record.summaryLength = SummaryLength.detailed.rawValue
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(record))
        #expect(decoded.resolvedSummaryLength == .detailed)
    }

    @Test func plainTranscriptIsCappedFromTheEnd() {
        var record = makeRecord()
        record.entries = (0..<500).map { i in
            .init(
                sourceText: "句子编号\(i) 很长很长很长",
                translation: "sentence number \(i)",
                speaker: nil,
                direction: LanguagePair(source: .chinese, target: .english),
                timestamp: .now)
        }
        let text = record.plainTranscript(limit: 1000)
        #expect(text.count <= 1000)
        #expect(text.contains("499"))   // newest content survives
    }

    @Test func codableRoundTrip() throws {
        let record = makeRecord()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(record))
        #expect(decoded.entries.count == 3)
        #expect(decoded.speakerNames[0] == "王老师")
        #expect(decoded.mode == .captions)
    }

    @Test func hotwordSuggestionParsing() {
        let builder = PromptBuilder()
        let raw = """
        Zhipeng | person name
        - Qwen | 通义千问 | model family
        2. Loqi | app name
        toolongtoolongtoolongtoolongtoolongtoolongtoolong | nope
        """
        let parsed = builder.parseHotwordSuggestions(raw, targetLanguage: .chinese)
        #expect(parsed.count == 3)
        #expect(parsed[0].term == "Zhipeng")
        #expect(parsed[0].note == "person name")
        #expect(parsed[1].term == "Qwen")
        #expect(parsed[1].renderings[.chinese] == "通义千问")
        #expect(parsed[1].note == "model family")
        #expect(parsed[2].term == "Loqi")
    }

    @Test func hotwordSuggestionsAreDeduplicated() {
        // Small models repeat themselves; duplicates become duplicate
        // SwiftUI ForEach identities downstream.
        let raw = """
        Zhipeng | person name
        zhipeng | repeated in different case
        Zhipeng | repeated verbatim
        Qwen | model
        """
        let parsed = PromptBuilder().parseHotwordSuggestions(raw)
        #expect(parsed.count == 2)
        #expect(parsed.map(\.term) == ["Zhipeng", "Qwen"])
    }

    @Test func decodesRecordWithoutChatHistory() throws {
        // Files written before chat existed must keep loading.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(makeRecord()))
        #expect(decoded.chatHistory == nil)
    }

    @Test func chatHistoryRoundTripsAndUnknownRoleSurvives() throws {
        var record = makeRecord()
        record.chatHistory = [
            .init(role: "user", text: "决定了什么？", date: Date(timeIntervalSince1970: 1_000_200)),
            .init(role: "assistant", text: "六月发布。", date: Date(timeIntervalSince1970: 1_000_210)),
            .init(role: "tool", text: "future role", date: Date(timeIntervalSince1970: 1_000_220)),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionRecord.self, from: encoder.encode(record))
        #expect(decoded.chatHistory?.count == 3)
        #expect(decoded.chatHistory?[0].isUser == true)
        #expect(decoded.chatHistory?[1].isUser == false)
        #expect(decoded.chatHistory?[2].role == "tool")   // raw String: never fails decode
    }
}
