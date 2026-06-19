import Foundation
import Testing

@testable import Loqi

/// Crash journal round-trip plus the launch recovery that consumes it.
/// Serialized: the journal is one well-known file on disk.
@Suite(.serialized)
@MainActor
struct SessionJournalTests {
    private func makeRecord(entryTexts: [String] = ["第一句", "第二句"]) -> SessionRecord {
        let direction = LanguagePair(source: .chinese, target: .chinese)
        let entries = entryTexts.map {
            SessionRecord.Entry(
                sourceText: $0, translation: nil, speaker: nil,
                direction: direction, timestamp: .now)
        }
        return SessionRecord(
            mode: .captions,
            startedAt: .now.addingTimeInterval(-60),
            endedAt: .now,
            entries: entries)
    }

    @Test func roundTripPreservesTheSnapshot() {
        defer { SessionJournal.clear() }
        var record = makeRecord()
        record.speakerNames = [0: "王经理"]
        SessionJournal.write(record)

        let recovered = SessionJournal.read()
        #expect(recovered?.id == record.id)
        #expect(recovered?.entries.map(\.sourceText) == ["第一句", "第二句"])
        #expect(recovered?.speakerNames == [0: "王经理"])
    }

    @Test func roundTripPreservesAttachmentOCR() {
        defer { SessionJournal.clear() }
        var record = makeRecord()
        record.attachments = [
            SessionRecord.Attachment(
                fileName: "slide.jpg", timestamp: .now, ocrText: "白板内容")
        ]
        SessionJournal.write(record)

        let recovered = SessionJournal.read()
        #expect(recovered?.attachments?.count == 1)
        #expect(recovered?.attachments?.first?.ocrText == "白板内容")
    }

    @Test func clearLeavesNothingToRecover() {
        SessionJournal.write(makeRecord())
        SessionJournal.clear()
        #expect(SessionJournal.read() == nil)
    }

    @Test func missingJournalReadsNil() {
        SessionJournal.clear()
        #expect(SessionJournal.read() == nil)
    }

    /// A journal left by a dead process surfaces as an archived session
    /// and the post-stop card in "interrupted" framing; the journal is
    /// consumed so the next launch is clean.
    @Test func pipelineRecoversInterruptedSession() {
        SessionJournal.clear()
        let record = makeRecord()
        SessionJournal.write(record)

        let pipeline = CaptionPipeline(llm: LLMService())
        defer {
            pipeline.archive.delete(id: record.id)
            SessionJournal.clear()
        }

        #expect(pipeline.archive.sessions.contains { $0.id == record.id })
        #expect(pipeline.lastFinishedSessionID == record.id)
        #expect(pipeline.lastFinishedWasInterrupted)
        #expect(SessionJournal.read() == nil)
    }

    /// The crash can race the clean shutdown: if the session already made
    /// it into the archive, recovery must not duplicate it.
    @Test func recoverySkipsAlreadyArchivedSession() {
        SessionJournal.clear()
        let record = makeRecord()

        let first = CaptionPipeline(llm: LLMService())
        first.archive.add(record)
        defer {
            first.archive.delete(id: record.id)
            SessionJournal.clear()
        }
        SessionJournal.write(record)

        let second = CaptionPipeline(llm: LLMService())
        #expect(second.archive.sessions.filter { $0.id == record.id }.count == 1)
        #expect(second.lastFinishedSessionID == nil)
    }
}
