import Foundation
import Testing
@testable import Loqi

struct SummaryStyleTests {
    let builder = PromptBuilder()

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

    /// The style the summary UI shows: stored per-session raw wins; a
    /// legacy summary without one was written meeting-shaped; otherwise
    /// the app default (garbage defaults fall back to meeting).
    @Test func effectiveStyleResolution() {
        #expect(SummaryStyle.effective(
            storedRaw: "journal", hasSummary: true, defaultRaw: "memo") == .journal)
        #expect(SummaryStyle.effective(
            storedRaw: nil, hasSummary: true, defaultRaw: "memo") == .meeting)
        #expect(SummaryStyle.effective(
            storedRaw: "from-the-future", hasSummary: true, defaultRaw: "memo") == .meeting)
        #expect(SummaryStyle.effective(
            storedRaw: nil, hasSummary: false, defaultRaw: "memo") == .memo)
        #expect(SummaryStyle.effective(
            storedRaw: nil, hasSummary: false, defaultRaw: "garbage") == .meeting)
    }

}
