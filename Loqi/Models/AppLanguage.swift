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

    /// The language the user reads Loqi in — what summaries should be
    /// written in (a zh UI wants zh summaries even of an en session).
    static var devicePreferred: AppLanguage? {
        if let language = AppUILanguage.current.readerLanguage {
            return language
        }
        return speechPreferred
    }

    /// The device's spoken-language guess (system language list), WITHOUT
    /// the app-UI override: Auto ASR must follow what the user likely
    /// SPEAKS, not what they read Loqi in — a zh UI plus English speech
    /// in Auto mode must not build a zh recognizer.
    static var speechPreferred: AppLanguage? {
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

    init?(speechRecognitionCode: String) {
        // sherpa-onnx SenseVoice reports the detected language as its raw
        // token ("<|zh|>"), not a bare code. Without stripping it, Auto
        // mode never detects anything: every utterance falls back to the
        // device language and live translation silently never triggers.
        var code = speechRecognitionCode
        if code.hasPrefix("<|") { code = String(code.dropFirst(2)) }
        if code.hasSuffix("|>") { code = String(code.dropLast(2)) }
        switch code {
        case "en": self = .english
        case "zh", "yue": self = .chinese
        case "ja": self = .japanese
        case "ko": self = .korean
        default: return nil
        }
    }
}

enum AppUILanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case chinese

    static let defaultsKey = "app.language"

    var id: String { rawValue }

    static var current: AppUILanguage {
        AppUILanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            ?? .system
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .chinese: Locale(identifier: "zh-Hans")
        }
    }

    var readerLanguage: AppLanguage? {
        switch self {
        case .system: nil
        case .english: .english
        case .chinese: .chinese
        }
    }
}

struct LanguagePair: Hashable, Codable, Sendable {
    var source: AppLanguage
    var target: AppLanguage

    var reversed: LanguagePair { LanguagePair(source: target, target: source) }

    var displayName: String { "\(source.displayName) → \(target.displayName)" }
}

enum RecognitionLanguageSelection: Hashable, Codable, Sendable {
    static let autoRawValue = "auto"

    case auto
    case language(AppLanguage)

    init(rawValue: String?) {
        if rawValue == Self.autoRawValue {
            self = .auto
        } else if let rawValue, let language = AppLanguage(rawValue: rawValue) {
            self = .language(language)
        } else {
            self = .language(.english)
        }
    }

    var rawValue: String {
        switch self {
        case .auto: Self.autoRawValue
        case .language(let language): language.rawValue
        }
    }

    var displayName: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .language(let language): language.displayName
        }
    }

    /// Fallback for APIs that still need a concrete locale before speech
    /// arrives, including the current Apple SpeechAnalyzer wrapper.
    /// Deliberately `speechPreferred`, not `devicePreferred`: the reader-
    /// language override must never steer which recognizer Auto builds.
    var fallbackLanguage: AppLanguage {
        switch self {
        case .auto: AppLanguage.speechPreferred ?? .english
        case .language(let language): language
        }
    }
}

struct RecognitionRoute: Hashable, Sendable {
    var source: RecognitionLanguageSelection
    /// nil means transcribe-only: each utterance targets its detected source.
    var target: AppLanguage?

    var fallbackDirection: LanguagePair {
        let fallback = source.fallbackLanguage
        return LanguagePair(source: fallback, target: target ?? fallback)
    }

    var displayName: String {
        if let target {
            "\(source.displayName) → \(target.displayName)"
        } else {
            source.displayName
        }
    }

    var possibleTranslationDirections: Set<LanguagePair> {
        guard let target else { return [] }
        switch source {
        case .auto:
            return Set(AppLanguage.allCases.compactMap { language in
                language == target ? nil : LanguagePair(source: language, target: target)
            })
        case .language(let language):
            return language == target ? [] : [LanguagePair(source: language, target: target)]
        }
    }

    /// Translation sessions are system-owned SwiftUI tasks. In Auto mode,
    /// don't mount every possible source→target task up front; create the
    /// concrete direction lazily when speech detection yields a language.
    var eagerTranslationDirections: Set<LanguagePair> {
        switch source {
        case .auto: []
        case .language: possibleTranslationDirections
        }
    }
}
