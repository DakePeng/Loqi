import Foundation

/// A language the app can transcribe and translate. v1 ships zh/en/ja;
/// adding a language means adding a case here and verifying its
/// SpeechTranscriber locale + Translation framework pairs at runtime.
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case english
    case chinese
    case japanese
    case korean

    var id: String { rawValue }

    /// Locale used for SpeechTranscriber asset allocation and transcription.
    var speechLocale: Locale {
        switch self {
        case .english: Locale(identifier: "en-US")
        case .chinese: Locale(identifier: "zh-CN")
        case .japanese: Locale(identifier: "ja-JP")
        case .korean: Locale(identifier: "ko-KR")
        }
    }

    /// Language used by the Translation framework.
    var translationLanguage: Locale.Language {
        switch self {
        case .english: Locale.Language(identifier: "en")
        case .chinese: Locale.Language(identifier: "zh-Hans")
        case .japanese: Locale.Language(identifier: "ja")
        case .korean: Locale.Language(identifier: "ko")
        }
    }

    var displayName: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

    /// English name used in LLM prompts.
    var promptName: String {
        switch self {
        case .english: "English"
        case .chinese: "Chinese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        }
    }

    /// Rough heuristic for the refinement skip rule: CJK text is denser
    /// than Latin text, so length thresholds differ.
    var usesCJKScript: Bool { self != .english }

    /// The language the user's phone runs in — what summaries should be
    /// written in (a zh user wants zh summaries even of an en session).
    static var devicePreferred: AppLanguage? {
        for identifier in Locale.preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            switch code {
            case "zh": return .chinese
            case "ja": return .japanese
            case "ko": return .korean
            case "en": return .english
            default: continue
            }
        }
        return nil
    }
}

struct LanguagePair: Hashable, Codable, Sendable {
    var source: AppLanguage
    var target: AppLanguage

    var reversed: LanguagePair { LanguagePair(source: target, target: source) }

    var displayName: String { "\(source.displayName) → \(target.displayName)" }
}
