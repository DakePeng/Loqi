import Foundation
import Testing
@testable import Loqi

struct AttachmentNotesTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func attachment(
        ocr: String? = nil, caption: String? = nil, described: String? = nil,
        at offset: TimeInterval = 0
    ) -> SessionRecord.Attachment {
        SessionRecord.Attachment(
            fileName: "x.jpg",
            timestamp: t0.addingTimeInterval(offset),
            ocrText: ocr,
            caption: caption,
            vlmDescription: described)
    }

    @Test func noteUsesOCRLinesAndPhotoHeadline() {
        let note = AttachmentNotes.note(for: attachment(
            ocr: "Q3 预算评审\n收入目标 1.2 亿\n\n  风险: 供应链  "))
        #expect(note != nil)
        #expect(note?.headline == "📷 Q3 预算评审")
        #expect(note?.facts == ["Q3 预算评审", "收入目标 1.2 亿", "风险: 供应链"])
    }

    @Test func textlessAttachmentProducesNoNote() {
        #expect(AttachmentNotes.note(for: attachment()) == nil)
        #expect(AttachmentNotes.note(for: attachment(ocr: "  \n ")) == nil)
    }

    @Test func captionLeadsAndCountsAsText() {
        let note = AttachmentNotes.note(for: attachment(
            ocr: "whiteboard text", caption: "架构草图"))
        #expect(note?.facts.first == "架构草图")
        #expect(note?.headline == "📷 架构草图")
        // Caption alone is enough.
        let captionOnly = AttachmentNotes.note(for: attachment(caption: "现场照片"))
        #expect(captionOnly?.facts == ["现场照片"])
    }

    @Test func descriptionWinsOCRIsFallback() {
        // Description present → it's the photo's summary, OCR is reference only.
        let note = AttachmentNotes.note(for: attachment(
            ocr: "5%", described: "Bar chart: churn dropping from 8% to 5% over Q1–Q3"))
        #expect(note?.facts.first?.hasPrefix("Bar chart") == true)
        // Even substantial OCR defers to the description in the summary.
        let slide = AttachmentNotes.note(for: attachment(
            ocr: "Roadmap 2026\nPhase 1: capture\nPhase 2: sync",
            described: "A slide"))
        #expect(slide?.facts == ["A slide"])
        // No description → OCR feeds the summary.
        let ocrOnly = AttachmentNotes.note(for: attachment(
            ocr: "Roadmap 2026\nPhase 1: capture"))
        #expect(ocrOnly?.facts.first == "Roadmap 2026")
    }

    @Test func longContentIsCapped() {
        let ocr = (1...12).map { "line number \($0) with some extra words" }
            .joined(separator: "\n")
        let note = AttachmentNotes.note(for: attachment(ocr: ocr))
        #expect(note?.facts.count == AttachmentNotes.summaryMaxLines)
        let longLine = String(repeating: "字", count: 200)
        let capped = AttachmentNotes.note(for: attachment(ocr: longLine))
        #expect(capped?.facts.first?.count == AttachmentNotes.maxLineLength)
        #expect(capped?.headline.count ?? 0 <= AttachmentNotes.headlineLength + 3)
    }

    @Test func mergeOrdersByTimeAndKeepsRealNotesFirstOnTies() {
        let notes = [
            SessionRecord.ChunkNote(headline: "one", startedAt: t0),
            SessionRecord.ChunkNote(headline: "two", startedAt: t0.addingTimeInterval(60)),
        ]
        let attachments = [
            attachment(ocr: "photo at 30", at: 30),
            attachment(ocr: "photo tied with two", at: 60),
        ]
        let merged = AttachmentNotes.merged(notes, attachments: attachments)
        #expect(merged.map(\.headline) == [
            "one", "📷 photo at 30", "two", "📷 photo tied with two",
        ])
        // No attachments → identical array back.
        #expect(AttachmentNotes.merged(notes, attachments: nil).map(\.id) == notes.map(\.id))
        // Textless attachments contribute nothing.
        #expect(AttachmentNotes.merged(notes, attachments: [attachment()]).count == 2)
    }

    @Test func markdownCollectsAllPhotosInOneSection() {
        let direction = LanguagePair(source: .chinese, target: .english)
        let entries = [
            SessionRecord.Entry(
                sourceText: "开始", direction: direction, timestamp: t0),
            SessionRecord.Entry(
                sourceText: "结束", direction: direction, timestamp: t0.addingTimeInterval(60)),
        ]
        var record = SessionRecord(
            mode: .captions, startedAt: t0, endedAt: t0.addingTimeInterval(100),
            entries: entries)
        record.attachments = [
            SessionRecord.Attachment(
                fileName: "a.jpg", timestamp: t0.addingTimeInterval(10),
                anchorEntryID: entries[0].id, ocrText: "看板内容"),
            SessionRecord.Attachment(
                fileName: "b.jpg", timestamp: t0.addingTimeInterval(90),
                ocrText: "白板照片", caption: "总结"),
        ]
        let md = record.markdown()
        #expect(md.contains("## Photos"))
        #expect(md.contains("> 看板内容"))
        #expect(md.contains("> 白板照片"))
        #expect(md.contains("*总结*"))
        // All photos trail the transcript, in timestamp order.
        let secondEntry = md.range(of: "> 结束")!
        let first = md.range(of: "看板内容")!
        let second = md.range(of: "白板照片")!
        #expect(secondEntry.upperBound < first.lowerBound)
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func markdownShowsDescriptionThenOCR() {
        var record = SessionRecord(
            mode: .captions, startedAt: t0, endedAt: t0, entries: [])
        record.attachments = [SessionRecord.Attachment(
            fileName: "a.jpg", timestamp: t0,
            ocrText: "raw text", vlmDescription: "a duck on a desk")]
        let md = record.markdown()
        // Description is plain prose; raw OCR is the quoted detail.
        #expect(md.contains("a duck on a desk"))
        #expect(!md.contains("> a duck on a desk"))
        #expect(md.contains("> raw text"))
    }
}
