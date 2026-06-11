import Testing
@testable import Locally

@MainActor
struct CaptionStoreTests {
    let enToZh = LanguagePair(source: .english, target: .chinese)

    @Test func volatileLifecycle() {
        let store = CaptionStore()
        let id = store.applyVolatile(text: "hello", direction: enToZh)
        #expect(store.activeEntryID == id)
        // Updates replace text on the same entry.
        let again = store.applyVolatile(text: "hello there", direction: enToZh)
        #expect(again == id)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.sourceText == "hello there")

        let final = store.finalizeActive(text: "hello there!", direction: enToZh)
        #expect(final?.id == id)
        #expect(final?.state == .finalized)
        #expect(store.activeEntryID == nil)
    }

    @Test func discardsEmptyActive() {
        let store = CaptionStore()
        store.applyVolatile(text: "x", direction: enToZh)
        // Simulate ASR retracting everything.
        store.applyVolatile(text: "", direction: enToZh)
        store.discardActiveIfEmpty()
        #expect(store.entries.isEmpty)
        #expect(store.activeEntryID == nil)
    }

    @Test func refinementLifecycle() {
        let store = CaptionStore()
        guard let entry = {
            store.applyVolatile(text: "hi", direction: enToZh)
            return store.finalizeActive(text: "hi there everyone", direction: enToZh)
        }() else {
            Issue.record("no entry")
            return
        }
        store.setDraft("大家好", for: entry.id)
        store.markRefining(entry.id)
        #expect(store.entry(for: entry.id)?.state == .refining)
        store.setRefined("大家好呀", for: entry.id)
        #expect(store.entry(for: entry.id)?.displayTranslation == "大家好呀")
        #expect(store.entry(for: entry.id)?.state == .refined)
    }

    @Test func draftFailureIsRecordedAndClearedBySuccess() {
        let store = CaptionStore()
        store.applyVolatile(text: "hi", direction: enToZh)
        guard let entry = store.finalizeActive(text: "hi", direction: enToZh) else {
            Issue.record("no entry")
            return
        }
        store.markDraftFailed(entry.id)
        #expect(store.entry(for: entry.id)?.draftFailed == true)
        store.setDraft("你好", for: entry.id)
        #expect(store.entry(for: entry.id)?.draftFailed == false)
    }

    @Test func modesAreIsolated() {
        let store = CaptionStore()
        store.currentMode = .captions
        store.applyVolatile(text: "caption line", direction: enToZh)
        store.finalizeActive(text: "caption line", direction: enToZh)

        store.currentMode = .conversation
        store.applyVolatile(text: "chat line", direction: enToZh)
        store.finalizeActive(text: "chat line", direction: enToZh)

        #expect(store.entries(in: .captions).count == 1)
        #expect(store.entries(in: .conversation).count == 1)

        store.clear(.captions)
        #expect(store.entries(in: .captions).isEmpty)
        #expect(store.entries(in: .conversation).count == 1)
    }

    @Test func historyOnlyDrawsFromCurrentMode() {
        let store = CaptionStore()
        store.currentMode = .captions
        store.applyVolatile(text: "lecture", direction: enToZh)
        if let entry = store.finalizeActive(text: "lecture", direction: enToZh) {
            store.setDraft("讲座", for: entry.id)
        }
        store.currentMode = .conversation
        #expect(store.recentHistory(limit: 6).isEmpty)
    }

    @Test func pruningKeepsNewestEntries() {
        let store = CaptionStore()
        for i in 0..<700 {
            store.applyVolatile(text: "line \(i)", direction: enToZh)
            store.finalizeActive(text: "line \(i)", direction: enToZh)
        }
        #expect(store.entries.count <= 600)
        #expect(store.entries.last?.sourceText == "line 699")
        // Oldest entries are the ones dropped.
        #expect(store.entries.first?.sourceText != "line 0")
    }

    @Test func finalizeActiveAsIsFreezesLeftoverVolatile() {
        let store = CaptionStore()
        let id = store.applyVolatile(text: "interrupted mid-sentence", direction: enToZh)
        let frozen = store.finalizeActiveAsIs()
        #expect(frozen?.id == id)
        #expect(frozen?.state == .finalized)
        #expect(store.activeEntryID == nil)
        // The next turn must open a NEW entry, never adopt the old one.
        let nextID = store.applyVolatile(text: "next speaker", direction: enToZh.reversed)
        #expect(nextID != id)
        #expect(store.entry(for: id)?.sourceText == "interrupted mid-sentence")
        #expect(store.entry(for: id)?.direction == enToZh)
    }

    @Test func finalizeActiveAsIsDropsEmptyVolatile() {
        let store = CaptionStore()
        store.applyVolatile(text: "x", direction: enToZh)
        store.applyVolatile(text: "", direction: enToZh)
        #expect(store.finalizeActiveAsIs() == nil)
        #expect(store.entries.isEmpty)
    }

    @Test func speakerAttribution() {
        let store = CaptionStore()
        store.applyVolatile(text: "hi", direction: enToZh)
        guard let entry = store.finalizeActive(text: "hi", direction: enToZh) else {
            Issue.record("no entry")
            return
        }
        store.setSpeaker(2, for: entry.id)
        #expect(store.entry(for: entry.id)?.speaker == 2)
    }
}
