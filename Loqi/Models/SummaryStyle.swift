import Foundation

/// What kind of summary the reduce phase writes. The map phase is
/// style-independent — live chunk notes are generated during recording,
/// before any style is known — so switching styles is a single reduce
/// generation over the cached notes, never a re-map.
enum SummaryStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case meeting        // default; reproduces the legacy summary exactly
    case memo
    case lecture
    case brainstorm
    case journal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meeting: String(localized: "Meeting")
        case .memo: String(localized: "Memo to self")
        case .lecture: String(localized: "Lecture / talk")
        case .brainstorm: String(localized: "Brainstorm")
        case .journal: String(localized: "Voice journal")
        }
    }

    var symbolName: String {
        switch self {
        case .meeting: "person.2.wave.2"
        case .memo: "checklist"
        case .lecture: "graduationcap"
        case .brainstorm: "lightbulb"
        case .journal: "book.closed"
        }
    }

    /// Everything the reduce step needs to write this style: the prompt's
    /// task sentence, the tagged output sections, and the headings baked
    /// into the generated markdown. Headings are a code table, not
    /// xcstrings — the summary's language follows the generation language,
    /// which is independent of the UI locale.
    struct Spec: Sendable {
        struct Section: Sendable {
            /// Single-letter line tag in the model's output ("T: …").
            let tag: String
            /// Max lines parsed for this section.
            let cap: Int
            /// Content hint shown in the reduce prompt: "T: <hint>".
            let hint: String
            let headings: [AppLanguage: String]

            func heading(for language: AppLanguage) -> String {
                headings[language] ?? headings[.english] ?? ""
            }
        }

        /// First sentence of the reduce system prompt.
        let task: String
        /// Max "O:" overview lines; rendered as the leading paragraph.
        let overviewCap: Int
        let overviewHint: String
        let sections: [Section]
        /// Feed chunk-note `terms` into the reduce input. Lecture only:
        /// adding terms shifts the input, and meeting output must not move.
        let includeTermsInNotes: Bool
    }

    var spec: Spec {
        switch self {
        case .meeting:
            Spec(
                task: "You combine sectioned meeting notes into one final summary.",
                overviewCap: 3,
                overviewHint: "overview sentence",
                sections: [
                    .init(tag: "T", cap: 4, hint: "main topic", headings: [
                        .english: "Topics", .chinese: "主题",
                        .japanese: "トピック", .korean: "주제",
                    ]),
                    .init(tag: "D", cap: 4, hint: "decision", headings: [
                        .english: "Decisions", .chinese: "决定",
                        .japanese: "決定事項", .korean: "결정 사항",
                    ]),
                    .init(tag: "A", cap: 5, hint: "action item, keep who does what", headings: [
                        .english: "Action Items", .chinese: "待办事项",
                        .japanese: "アクションアイテム", .korean: "액션 아이템",
                    ]),
                ],
                includeTermsInNotes: false)
        case .memo:
            Spec(
                task: "You combine notes from a spoken voice memo into one short memo to self.",
                overviewCap: 2,
                overviewHint: "gist of the memo",
                sections: [
                    .init(tag: "K", cap: 5, hint: "key point to remember", headings: [
                        .english: "Key Points", .chinese: "要点",
                        .japanese: "ポイント", .korean: "핵심 사항",
                    ]),
                    .init(tag: "A", cap: 5, hint: "to-do, start with a verb", headings: [
                        .english: "To-Dos", .chinese: "待办事项",
                        .japanese: "やること", .korean: "할 일",
                    ]),
                ],
                includeTermsInNotes: false)
        case .lecture:
            Spec(
                task: "You combine notes from a lecture or talk into one clear study summary.",
                overviewCap: 3,
                overviewHint: "overview of what the talk covered",
                sections: [
                    .init(tag: "C", cap: 5, hint: "key concept or takeaway", headings: [
                        .english: "Key Concepts", .chinese: "核心概念",
                        .japanese: "重要概念", .korean: "핵심 개념",
                    ]),
                    .init(tag: "T", cap: 5, hint: "important term or name, with a brief explanation", headings: [
                        .english: "Terms", .chinese: "术语",
                        .japanese: "用語", .korean: "용어",
                    ]),
                    .init(tag: "Q", cap: 4, hint: "open question worth following up", headings: [
                        .english: "Open Questions", .chinese: "疑问",
                        .japanese: "疑問点", .korean: "남은 질문",
                    ]),
                ],
                includeTermsInNotes: true)
        case .brainstorm:
            Spec(
                task: "You combine notes from a brainstorming session into one summary of the ideas.",
                overviewCap: 2,
                overviewHint: "what the brainstorm was about",
                sections: [
                    .init(tag: "I", cap: 6, hint: "distinct idea, one line", headings: [
                        .english: "Ideas", .chinese: "想法",
                        .japanese: "アイデア", .korean: "아이디어",
                    ]),
                    .init(tag: "S", cap: 3, hint: "standout idea worth pursuing first", headings: [
                        .english: "Standouts", .chinese: "重点想法",
                        .japanese: "注目アイデア", .korean: "주목할 아이디어",
                    ]),
                    .init(tag: "A", cap: 4, hint: "next step, keep who does what", headings: [
                        .english: "Next Steps", .chinese: "后续行动",
                        .japanese: "次のステップ", .korean: "다음 단계",
                    ]),
                ],
                includeTermsInNotes: false)
        case .journal:
            // Tag "N" (not "I") for intentions: a bare "I" line invites the
            // model to continue the pronoun instead of tagging.
            Spec(
                task: "You turn notes from a spoken personal journal entry into a short reflective diary summary.",
                overviewCap: 4,
                overviewHint: "sentence on what happened, in order",
                sections: [
                    .init(tag: "H", cap: 4, hint: "highlight or memorable moment", headings: [
                        .english: "Highlights", .chinese: "亮点",
                        .japanese: "ハイライト", .korean: "하이라이트",
                    ]),
                    .init(tag: "F", cap: 4, hint: "feeling or reflection the speaker expressed", headings: [
                        .english: "Feelings & Reflections", .chinese: "感受与思考",
                        .japanese: "気持ちと振り返り", .korean: "감정과 생각",
                    ]),
                    .init(tag: "N", cap: 4, hint: "intention or plan for the future", headings: [
                        .english: "Intentions", .chinese: "打算",
                        .japanese: "これからのこと", .korean: "다짐",
                    ]),
                ],
                includeTermsInNotes: false)
        }
    }
}
