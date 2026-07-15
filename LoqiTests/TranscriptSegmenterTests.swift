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
    @Test func appleSettingResolvesApple() {
        let resolved = CaptionPipeline.resolveASRKind(
            setting: "apple", senseVoiceInstalled: true, source: .language(.japanese))
        #expect(resolved.kind == "apple")
        #expect(resolved.notice == nil)
    }

    @Test func nilSettingResolvesApple() {
        let resolved = CaptionPipeline.resolveASRKind(
            setting: nil, senseVoiceInstalled: true, source: .auto)
        #expect(resolved.kind == "apple")
        #expect(resolved.notice == nil)
    }

    @Test func senseVoiceInstalledResolvesSenseVoice() {
        let resolved = CaptionPipeline.resolveASRKind(
            setting: "sensevoice", senseVoiceInstalled: true, source: .auto)
        #expect(resolved.kind == "sensevoice")
        #expect(resolved.notice == nil)
    }

    @Test func senseVoiceMissingFallsBackToAppleWithNotice() {
        let resolved = CaptionPipeline.resolveASRKind(
            setting: "sensevoice", senseVoiceInstalled: false, source: .auto)
        #expect(resolved.kind == "apple")
        #expect(resolved.notice == .modelMissing)
    }

    @Test func hybridInstalledConcreteResolvesHybrid() {
        let resolved = CaptionPipeline.resolveASRKind(
            setting: "hybrid", senseVoiceInstalled: true, source: .language(.japanese))
        #expect(resolved.kind == "hybrid")
        #expect(resolved.notice == nil)
    }

    @Test func hybridWithAutoFallsBackToSenseVoiceWithNotice() {
        let resolved = CaptionPipeline.resolveASRKind(
            setting: "hybrid", senseVoiceInstalled: true, source: .auto)
        #expect(resolved.kind == "sensevoice")
        #expect(resolved.notice == .hybridNeedsConcreteLanguage)
    }

    @Test func hybridMissingModelFallsBackToAppleWithNotice() {
        let resolved = CaptionPipeline.resolveASRKind(
            setting: "hybrid", senseVoiceInstalled: false, source: .language(.chinese))
        #expect(resolved.kind == "apple")
        #expect(resolved.notice == .modelMissing)
    }
}
