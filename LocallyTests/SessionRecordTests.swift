import Foundation
import Testing
@testable import Locally

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

    @Test func markdownContainsSpeakersAndBothLanguages() {
        let md = makeRecord().markdown()
        #expect(md.contains("**王老师**"))          // custom name
        #expect(md.contains("**Speaker 2**"))       // default label
        #expect(md.contains("> 大家好"))
        #expect(md.contains("> Hello everyone"))
        #expect(md.contains("## Transcript"))
    }

    @Test func markdownIncludesSummaryWhenPresent() {
        var record = makeRecord()
        record.summary = "A lecture about translation."
        let md = record.markdown()
        #expect(md.contains("## Summary"))
        #expect(md.contains("A lecture about translation."))
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
        - Qwen | model family
        2. Locally | app name
        toolongtoolongtoolongtoolongtoolongtoolongtoolong | nope
        """
        let parsed = builder.parseHotwordSuggestions(raw)
        #expect(parsed.count == 3)
        #expect(parsed[0].term == "Zhipeng")
        #expect(parsed[0].note == "person name")
        #expect(parsed[1].term == "Qwen")
        #expect(parsed[2].term == "Locally")
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
}
