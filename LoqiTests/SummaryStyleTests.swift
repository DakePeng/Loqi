import Foundation
import Testing
@testable import Loqi

struct SummaryStyleTests {
    let builder = PromptBuilder()

    /// Pins the exact meeting prompt bytes so they only change on purpose.
    /// Originally pinned to the pre-styles legacy prompt; deliberately
    /// re-pinned 2026-06 when the grounding sentences ("use only the
    /// notes…") were added to curb hallucinated summary content.
    @Test func meetingReducePromptIsPinned() {
        let english = builder.reduceSummaryPrompt(
            notes: "x", style: .meeting, in: .english)
        #expect(english.system == """
        You combine sectioned meeting notes into one final summary. Write \
        entirely in English. Plain text, no markdown. Output ONLY tagged \
        lines: first 1-3 lines "O: <overview sentence>", then up to 4 lines \
        "T: <main topic>", up to 4 lines "D: <decision>", up to 5 lines \
        "A: <action item, keep who does what>". Use only information from \
        the notes; keep O lines high-level; do not repeat the same details \
        that you put in the tagged section lines. Never invent names, numbers, or events. Keep names, \
        numbers, and dates exactly as written in the notes. Skip categories \
        with nothing to report. Merge duplicates. No other text.
        """)
        #expect(english.user == "Notes:\nx")

        let chinese = builder.reduceSummaryPrompt(notes: "x", in: .chinese)
        #expect(chinese.system.contains("Write entirely in Chinese."))
        #expect(chinese.system == english.system.replacingOccurrences(
            of: "in English", with: "in Chinese"))
    }

    @Test func specsAreWellFormed() {
        for style in SummaryStyle.allCases {
            let spec = style.spec
            #expect(!style.displayName.isEmpty)
            #expect(!style.symbolName.isEmpty)
            #expect(!spec.task.isEmpty)
            #expect(spec.overviewCap >= 1)
            #expect(!spec.overviewHint.isEmpty)
            #expect(!spec.sections.isEmpty)

            // "O" is reserved for the overview; tags are single Latin
            // letters and unique within the style.
            let tags = spec.sections.map(\.tag)
            #expect(Set(tags).count == tags.count)
            for section in spec.sections {
                #expect(section.tag.count == 1)
                #expect(section.tag != "O")
                #expect(section.tag.unicodeScalars.allSatisfy {
                    CharacterSet.uppercaseLetters.contains($0)
                })
                #expect(section.cap >= 1)
                #expect(!section.hint.isEmpty)
                for language in AppLanguage.allCases {
                    #expect(!section.heading(for: language).isEmpty)
                    #expect(section.headings[language] != nil)
                }
            }
        }
    }

    @Test func reducePromptListsEverySectionPerStyle() {
        for style in SummaryStyle.allCases {
            for language in AppLanguage.allCases {
                let prompt = builder.reduceSummaryPrompt(
                    notes: "x", style: style, in: language).system
                #expect(prompt.contains("Write entirely in \(language.promptName)."))
                let spec = style.spec
                #expect(prompt.contains(
                    "first 1-\(spec.overviewCap) lines \"O: <\(spec.overviewHint)>\""))
                for section in spec.sections {
                    #expect(prompt.contains(
                        "up to \(section.cap) lines \"\(section.tag): <\(section.hint)>\""))
                }
            }
        }
    }

    @Test func reduceInputIncludesTermsOnlyForLecture() {
        let note = SessionRecord.ChunkNote(
            headline: "Transformer basics",
            startedAt: .now,
            facts: ["Attention is quadratic"],
            decisions: ["Use KV cache"],
            actions: ["Read the paper"],
            terms: ["KV cache"])

        // Meeting input keeps the exact pre-style line format.
        let meeting = SummaryEngine.reduceInput(notes: [note], style: .meeting)
        #expect(meeting == """
        [1] Transformer basics
        fact: Attention is quadratic
        decision: Use KV cache
        action: Read the paper
        """)

        let lecture = SummaryEngine.reduceInput(notes: [note], style: .lecture)
        #expect(lecture.contains("term: KV cache"))
        for style in SummaryStyle.allCases where style != .lecture {
            #expect(!SummaryEngine.reduceInput(notes: [note], style: style)
                .contains("term: "))
        }
    }
}
