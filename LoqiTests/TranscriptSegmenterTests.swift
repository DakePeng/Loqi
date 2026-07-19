import Foundation
import Testing
@testable import Loqi

struct TranscriptSegmenterTests {
    let segmenter = TranscriptSegmenter()

    @Test func volatileTextPassesThroughTrimmed() {
        let output = segmenter.process(
            .volatile("  hello there ", language: nil),
            fallbackLanguage: .english)
        #expect(output?.kind == .volatileUpdate)
        #expect(output?.text == "hello there")
    }

    @Test func emptyVolatileIsIgnored() {
        #expect(segmenter.process(
            .volatile("   ", language: nil),
            fallbackLanguage: .english) == nil)
    }

    @Test func emptyFinalDiscardsEntry() {
        let output = segmenter.process(
            .finalized("  ", runs: nil, language: nil),
            fallbackLanguage: .english)
        #expect(output?.kind == .discard)
    }

    @Test func punctuationOnlyFinalDiscardsEntry() {
        // Silence/noise yields lone-dot finals ("." / "。"); they must not
        // become entries.
        #expect(segmenter.process(
            .finalized("。", runs: nil, language: nil), fallbackLanguage: .chinese)?.kind == .discard)
        #expect(segmenter.process(
            .finalized(" . ", runs: nil, language: nil), fallbackLanguage: .english)?.kind == .discard)
        // And the volatile equivalent is ignored outright.
        #expect(segmenter.process(
            .volatile("。", language: nil), fallbackLanguage: .chinese) == nil)
    }

    @Test func shortEnglishFinalSkipsRefinement() {
        let output = segmenter.process(
            .finalized("Thank you", runs: nil, language: nil),
            fallbackLanguage: .english)
        #expect(output?.kind == .finalized(refine: false))
    }

    @Test func longEnglishFinalGetsRefinement() {
        let output = segmenter.process(
            .finalized("Could you tell me how much this would cost with shipping?", runs: nil, language: nil),
            fallbackLanguage: .english)
        #expect(output?.kind == .finalized(refine: true))
    }

    @Test func shortCJKFinalSkipsRefinement() {
        let output = segmenter.process(
            .finalized("谢谢你", runs: nil, language: nil),
            fallbackLanguage: .chinese)
        #expect(output?.kind == .finalized(refine: false))
    }

    @Test func longCJKFinalGetsRefinement() {
        let output = segmenter.process(
            .finalized("お世話になっております。価格についてご相談したいのですが。", runs: nil, language: nil),
            fallbackLanguage: .japanese)
        #expect(output?.kind == .finalized(refine: true))
    }

    @Test func detectedLanguageOverridesFallback() {
        let output = segmenter.process(
            .finalized("谢谢大家", runs: nil, language: .chinese),
            fallbackLanguage: .english)
        #expect(output?.language == .chinese)
        #expect(output?.languageWasDetected == true)
    }

    @Test func endedEventProducesNothing() {
        #expect(segmenter.process(.ended(nil), fallbackLanguage: .english) == nil)
    }
}

/// Hosted here rather than a new file: the xcodegen-generated pbxproj
/// (pending local edits) lists test files explicitly.
struct HybridVolatileComposerTests {
    private func speakingComposer(separator: String = " ") -> HybridVolatileComposer {
        var composer = HybridVolatileComposer(separator: separator)
        composer.setSpeaking(true)
        return composer
    }

    @Test func volatileComposesWhileSpeaking() {
        var composer = speakingComposer()
        #expect(composer.appleVolatile("hello") == "hello")
        #expect(composer.appleVolatile("hello there") == "hello there")
    }

    @Test func volatileSuppressedWhileNotSpeaking() {
        var composer = HybridVolatileComposer(separator: " ")
        #expect(composer.appleVolatile("hello") == nil)
        composer.setSpeaking(true)
        #expect(composer.appleVolatile("hello again") == "hello again")
        composer.setSpeaking(false)
        #expect(composer.appleVolatile("hello more") == nil)
    }

    @Test func appleFinalMidSegmentStaysVisible() {
        // Apple endpointed before silero closed the segment: its words
        // must stay in the gray row until the SenseVoice final lands.
        var composer = speakingComposer()
        #expect(composer.appleFinal("one two.") == "one two.")
        #expect(composer.appleVolatile("three") == "one two. three")
    }

    @Test func senseVoiceFinalResetsComposition() {
        var composer = speakingComposer()
        #expect(composer.appleVolatile("a b") == "a b")
        composer.senseVoiceFinalized()
        // The same Apple text re-emitted is fully consumed — it must not
        // resurrect a gray row after the final.
        #expect(composer.appleVolatile("a b") == nil)
    }

    @Test func staleVolatileAfterFinalIsTrimmed() {
        // Apple's utterance spans the silero close: only the new words
        // past the consumed prefix appear.
        var composer = speakingComposer()
        #expect(composer.appleVolatile("a b") == "a b")
        composer.senseVoiceFinalized()
        #expect(composer.appleVolatile("a b c") == "c")
    }

    @Test func lateAppleFinalAfterSVFinalIsDropped() {
        // A late Apple final whose content the SenseVoice final already
        // covered trims to punctuation-only and vanishes.
        var composer = speakingComposer()
        #expect(composer.appleVolatile("a b") == "a b")
        composer.senseVoiceFinalized()
        #expect(composer.appleFinal("a b.") == nil)
    }

    @Test func appleRevisionFallsBackToLCP() {
        // Apple revised a word inside the consumed prefix: the trim
        // shortens to the common part; transient duplication is acceptable
        // for gray text.
        var composer = speakingComposer()
        #expect(composer.appleVolatile("a b") == "a b")
        composer.senseVoiceFinalized()
        #expect(composer.appleVolatile("a c") == "c")
    }

    @Test func cjkComposesWithoutSpaces() {
        var composer = speakingComposer(separator: "")
        #expect(composer.appleFinal("你好。") == "你好。")
        #expect(composer.appleVolatile("世界") == "你好。世界")
    }

    @Test func multipleSVFinalsWithinOneAppleUtterance() {
        var composer = speakingComposer(separator: "")
        #expect(composer.appleVolatile("一二") == "一二")
        composer.senseVoiceFinalized()
        #expect(composer.appleVolatile("一二三四") == "三四")
        composer.senseVoiceFinalized()
        #expect(composer.appleVolatile("一二三四五") == "五")
    }

    @Test func duplicateComposedIsNotReemitted() {
        var composer = speakingComposer()
        #expect(composer.appleVolatile("same text") == "same text")
        #expect(composer.appleVolatile("same text") == nil)
    }

    @Test func appleFinalClearsConsumedPrefixForNextUtterance() {
        // After Apple closes its utterance, the next volatile is a fresh
        // utterance — the old consumed prefix must not trim it.
        var composer = speakingComposer()
        #expect(composer.appleVolatile("hello") == "hello")
        composer.senseVoiceFinalized()
        #expect(composer.appleFinal("hello.") == nil)
        #expect(composer.appleVolatile("hi") == "hi")
    }
}

struct ASRKindResolutionTests {
    @Test func installedConcreteResolvesHybrid() {
        let resolved = CaptionPipeline.resolveASRKind(
            senseVoiceInstalled: true, source: .language(.japanese))
        #expect(resolved.kind == "hybrid")
        #expect(resolved.notice == nil)
    }

    @Test func installedAutoFallsBackToSenseVoiceSilently() {
        // Auto keeps per-utterance language detection on pure SenseVoice —
        // no status pill; the fallback is the intended Auto behavior.
        let resolved = CaptionPipeline.resolveASRKind(
            senseVoiceInstalled: true, source: .auto)
        #expect(resolved.kind == "sensevoice")
        #expect(resolved.notice == nil)
    }

    @Test func missingModelFallsBackToAppleWithNotice() {
        let resolved = CaptionPipeline.resolveASRKind(
            senseVoiceInstalled: false, source: .language(.chinese))
        #expect(resolved.kind == "apple")
        #expect(resolved.notice == .modelMissing)
    }

    @Test func missingModelAutoFallsBackToAppleWithNotice() {
        let resolved = CaptionPipeline.resolveASRKind(
            senseVoiceInstalled: false, source: .auto)
        #expect(resolved.kind == "apple")
        #expect(resolved.notice == .modelMissing)
    }

    @Test func dolphinFinalsGate() {
        // Auto (the default) upgrades 中/日/한 finals when the model is
        // installed; "sensevoice" vetoes the upgrade; English and .auto
        // never upgrade regardless of choice.
        #expect(SenseVoiceEngine.usesDolphinFinals(
            choice: "auto", preferred: true, dolphinInstalled: true,
            source: .language(.japanese)))
        #expect(!SenseVoiceEngine.usesDolphinFinals(
            choice: "sensevoice", preferred: true, dolphinInstalled: true,
            source: .language(.japanese)))
        #expect(!SenseVoiceEngine.usesDolphinFinals(
            choice: "auto", preferred: false, dolphinInstalled: true,
            source: .language(.japanese)))
        #expect(!SenseVoiceEngine.usesDolphinFinals(
            choice: "auto", preferred: true, dolphinInstalled: false,
            source: .language(.japanese)))
        #expect(!SenseVoiceEngine.usesDolphinFinals(
            choice: "auto", preferred: true, dolphinInstalled: true,
            source: .language(.english)))
        #expect(!SenseVoiceEngine.usesDolphinFinals(
            choice: "auto", preferred: true, dolphinInstalled: true,
            source: .auto))
    }
}

struct UtteranceMergerTests {
    private func u(_ text: String, _ start: TimeInterval, _ end: TimeInterval)
        -> UtteranceMerger.Utterance { (text, start, end) }

    @Test func endsSentenceTruthTable() {
        #expect(UtteranceMerger.endsSentence("今日は会議です。"))
        #expect(UtteranceMerger.endsSentence("完了！"))
        #expect(UtteranceMerger.endsSentence("そうですか？"))
        #expect(UtteranceMerger.endsSentence("Done."))
        #expect(UtteranceMerger.endsSentence("Really?"))
        #expect(UtteranceMerger.endsSentence("Wait…"))
        // Trailing closers and whitespace after the terminal mark.
        #expect(UtteranceMerger.endsSentence("彼は「はい。」"))
        #expect(UtteranceMerger.endsSentence("He said \"stop.\" "))
        // Non-terminal punctuation and bare text.
        #expect(!UtteranceMerger.endsSentence("今日は会議、"))
        #expect(!UtteranceMerger.endsSentence("and then we"))
        #expect(!UtteranceMerger.endsSentence("句読点なしの断片"))
        #expect(!UtteranceMerger.endsSentence(""))
    }

    @Test func capSplitHealsIntoOneSentence() {
        // A 12s cap split leaves ~zero gap; the tail completes the sentence.
        let merged = UtteranceMerger.merge([
            u("会議の予算については来年以降", 0, 12),
            u("事業部からもらいます。", 12.05, 17),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].text == "会議の予算については来年以降事業部からもらいます。")
        #expect(merged[0].start == 0)
        #expect(merged[0].end == 17)
    }

    @Test func joinerIsCJKAware() {
        #expect(UtteranceMerger.joiner(between: "予算は", and: "来年") == "")
        #expect(UtteranceMerger.joiner(between: "and then", and: "we left") == " ")
        // Mixed boundary gets a space.
        #expect(UtteranceMerger.joiner(between: "using G1", and: "です") == " ")
        // Sentences joining across CJK terminal punctuation stay spaceless.
        #expect(UtteranceMerger.joiner(between: "終わりました。", and: "次です") == "")
        #expect(UtteranceMerger.joiner(between: "そうです！", and: "「はい」") == "")
    }

    @Test func mergeStopsAtBoundaries() {
        // Terminal punctuation ends the group.
        #expect(UtteranceMerger.merge([
            u("終わりました。", 0, 3), u("次の話です", 3.2, 6),
        ]).count == 2)
        // Gap beyond maxGap ends it.
        #expect(UtteranceMerger.merge([
            u("それで", 0, 3), u("続きです", 4.5, 6),
        ]).count == 2)
        // Span beyond maxDuration ends it (12 + 12 cap split).
        #expect(UtteranceMerger.merge([
            u("長い話が", 0, 12), u("まだ続いていて", 12.01, 24),
        ]).count == 2)
        // Character cap ends it.
        #expect(UtteranceMerger.merge([
            u(String(repeating: "あ", count: 150), 0, 5),
            u(String(repeating: "い", count: 80), 5.1, 9),
        ], maxCharacters: 200).count == 2)
    }

    @Test func turnChangeGapDoesNotMerge() {
        // A silence-closed segment sits ≥0.5s (VAD minSilence) past the
        // previous one — this is EVERY speaker turn change. It must not
        // fuse into the prior fragment even without terminal punctuation,
        // or diarization would attribute both turns to one speaker. (Under
        // the old 0.8s gap this 0.5s pair merged into one.)
        #expect(UtteranceMerger.merge([
            u("はいそうです", 0, 3), u("私もそう思います", 3.5, 6),
        ]).count == 2)
        // A forced mid-speech cap-split (~0 gap, same speaker continuing)
        // still heals into one sentence.
        #expect(UtteranceMerger.merge([
            u("まだ話が続いていて", 0, 12), u("終わりました。", 12.03, 15),
        ]).count == 1)
    }

    @Test func chainAndPassthroughAndOverlap() {
        // Three fragments chain into one sentence.
        let chained = UtteranceMerger.merge([
            u("まず", 0, 2), u("予算の", 2.3, 4), u("話です。", 4.2, 6),
        ])
        #expect(chained.count == 1)
        #expect(chained[0].text == "まず予算の話です。")
        // Empty and single-element pass through.
        #expect(UtteranceMerger.merge([]).isEmpty)
        #expect(UtteranceMerger.merge([u("一つだけ", 0, 2)]).count == 1)
        // Overlapping ranges (retry-halves rescue) count as zero gap.
        #expect(UtteranceMerger.merge([
            u("重なって", 0, 4), u("います。", 3.5, 6),
        ]).count == 1)
    }

    @Test func sameSpeakerHealsPauseBrokenSentence() {
        // A 0.6s thinking pause closes the VAD segment; with both halves
        // attributed to the same speaker the sentence heals — the case the
        // blind merge can never fix (its gap sits below the VAD silence).
        let (merged, slots) = UtteranceMerger.mergeAttributed([
            u("会議の予算は", 0, 3), u("来年からです。", 3.6, 6),
        ], slots: [0, 0])
        #expect(merged.count == 1)
        #expect(merged[0].text == "会議の予算は来年からです。")
        #expect(slots == [0])
    }

    @Test func sameSpeakerSentencesJoinIntoParagraph() {
        // Complete sentences from one speaker flow together (paragraph-
        // shaped entries), still bounded by the duration/character caps.
        let (merged, slots) = UtteranceMerger.mergeAttributed([
            u("終わりました。", 0, 3), u("次の話です。", 3.8, 6),
        ], slots: [1, 1])
        #expect(merged.count == 1)
        #expect(slots == [1])
        // Beyond sameSpeakerGap they stay apart.
        #expect(UtteranceMerger.mergeAttributed([
            u("終わりました。", 0, 3), u("次の話です。", 5, 8),
        ], slots: [1, 1]).utterances.count == 2)
    }

    @Test func differentOrUnknownSpeakersNeverFuse() {
        // Different slots: no merge even at a cap-split-sized gap.
        #expect(UtteranceMerger.mergeAttributed([
            u("それで", 0, 3), u("続きです", 3.05, 6),
        ], slots: [0, 1]).utterances.count == 2)
        // Slot next to nil: no merge (attribution is uncertain there).
        #expect(UtteranceMerger.mergeAttributed([
            u("それで", 0, 3), u("続きです", 3.05, 6),
        ], slots: [0, nil]).utterances.count == 2)
        // nil/nil neighbors keep the conservative blind rules: a 0.6s
        // pause still splits, a ~0 cap-split gap still heals.
        #expect(UtteranceMerger.mergeAttributed([
            u("それで", 0, 3), u("続きです", 3.6, 6),
        ], slots: [nil, nil]).utterances.count == 2)
        let (healed, healedSlots) = UtteranceMerger.mergeAttributed([
            u("それで", 0, 3), u("続きです", 3.05, 6),
        ], slots: [nil, nil])
        #expect(healed.count == 1)
        #expect(healedSlots == [nil])
    }
}
