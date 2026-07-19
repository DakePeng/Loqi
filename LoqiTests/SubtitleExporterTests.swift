import Foundation
import Testing
@testable import Loqi

struct SubtitleExporterTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let direction = LanguagePair(source: .chinese, target: .english)

    private func record(
        offsets: [(text: String, translation: String?, audio: TimeInterval?, wall: TimeInterval)]
    ) -> SessionRecord {
        SessionRecord(
            mode: .captions,
            startedAt: t0,
            endedAt: t0.addingTimeInterval(600),
            entries: offsets.map {
                SessionRecord.Entry(
                    sourceText: $0.text,
                    translation: $0.translation,
                    direction: direction,
                    timestamp: t0.addingTimeInterval($0.wall),
                    audioOffset: $0.audio)
            })
    }

    @Test func timestampFormatting() {
        #expect(SubtitleExporter.timestamp(0, fraction: ",") == "00:00:00,000")
        #expect(SubtitleExporter.timestamp(75.5, fraction: ",") == "00:01:15,500")
        #expect(SubtitleExporter.timestamp(3_661.042, fraction: ".") == "01:01:01.042")
        #expect(SubtitleExporter.timestamp(-3, fraction: ",") == "00:00:00,000")
    }

    @Test func cueEndsAtNextStartOrFourSecondCap() {
        let record = record(offsets: [
            ("一", nil, 0, 0),
            ("二", nil, 2, 2),
            ("三", nil, 30, 30),  // long silence before
        ])
        let cues = SubtitleExporter.cues(for: record, bilingual: false)
        #expect(cues.count == 3)
        #expect(cues[0] == .init(start: 0, end: 2, lines: ["一"]))
        #expect(cues[1].end == 6)   // capped at +4s, not stretched to 30
        #expect(cues[2].end == 34)  // tail cue: +4s
    }

    @Test func bilingualAddsTranslationLine() {
        let record = record(offsets: [
            ("你好", "Hello", 0, 0),
            ("再见", nil, 5, 5),
        ])
        let mono = SubtitleExporter.cues(for: record, bilingual: false)
        let dual = SubtitleExporter.cues(for: record, bilingual: true)
        #expect(mono[0].lines == ["你好"])
        #expect(dual[0].lines == ["你好", "Hello"])
        #expect(dual[1].lines == ["再见"])  // no translation, single line
    }

    @Test func wallClockFallbackWhenOffsetsMissing() {
        let record = record(offsets: [
            ("a", nil, nil, 10),
            ("b", nil, nil, 14),
        ])
        let cues = SubtitleExporter.cues(for: record, bilingual: false)
        #expect(cues[0].start == 10)
        #expect(cues[0].end == 14)
    }

    @Test func identicalTimestampsStayMonotonicAndNonOverlapping() {
        let record = record(offsets: [
            ("a", nil, 1, 1),
            ("b", nil, 1, 1),
            ("c", nil, 1, 1),
        ])
        let cues = SubtitleExporter.cues(for: record, bilingual: false)
        for index in cues.indices.dropFirst() {
            #expect(cues[index].start > cues[index - 1].start)
            #expect(cues[index - 1].end <= cues[index].start)
        }
        for cue in cues {
            #expect(cue.end > cue.start)
        }
    }

    @Test func srtAndVttFormatting() {
        let cues = [
            SubtitleExporter.Cue(start: 0, end: 2, lines: ["你好", "Hello"]),
            SubtitleExporter.Cue(start: 2, end: 5.25, lines: ["bye"]),
        ]
        let srt = SubtitleExporter.srt(cues)
        #expect(srt.contains("1\n00:00:00,000 --> 00:00:02,000\n你好\nHello"))
        #expect(srt.contains("2\n00:00:02,000 --> 00:00:05,250\nbye"))
        let vtt = SubtitleExporter.vtt(cues)
        #expect(vtt.hasPrefix("WEBVTT\n\n"))
        #expect(vtt.contains("00:00:02.000 --> 00:00:05.250\nbye"))
        #expect(!vtt.contains(","))
    }

    @Test func emptyRecordProducesEmptyOutput() {
        let record = record(offsets: [])
        let cues = SubtitleExporter.cues(for: record, bilingual: false)
        #expect(cues.isEmpty)
    }
}

extension SubtitleExporterTests {
    /// Sentence-merged entries span up to ~20s; the tail hold scales with
    /// reading length instead of going dark after a flat 4s.
    @Test func cueHoldScalesWithLineLength() {
        #expect(SubtitleExporter.holdDuration(forCharacterCount: 5) == 4)
        #expect(SubtitleExporter.holdDuration(forCharacterCount: 96) == 8)
        #expect(SubtitleExporter.holdDuration(forCharacterCount: 400) == 10)

        let long = String(repeating: "长", count: 120)   // 10s hold
        let record = record(offsets: [
            (long, nil, 0, 0),
            ("短。", nil, 30, 30),
        ])
        let cues = SubtitleExporter.cues(for: record, bilingual: false)
        #expect(cues[0].end == 10)
        // A successor inside the hold still trims the cue.
        let trimmed = SubtitleExporter.cues(for: self.record(offsets: [
            (long, nil, 0, 0),
            ("短。", nil, 6, 6),
        ]), bilingual: false)
        #expect(trimmed[0].end == 6)
    }
}
