import Testing
@testable import Loqi

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

    /// Pruning must hand the dropped entries to `onEvict` so the owner can
    /// keep them — a session longer than the render window archives its whole
    /// transcript, not just the tail still on screen.
    @Test func evictionDeliversDroppedEntriesForArchival() {
        let store = CaptionStore()
        var evicted: [CaptionEntry] = []
        store.onEvict = { evicted.append(contentsOf: $0) }
        for i in 0..<700 {
            store.applyVolatile(text: "line \(i)", direction: enToZh)
            store.finalizeActive(text: "line \(i)", direction: enToZh)
        }
        // Something was actually pushed out of the window…
        #expect(!evicted.isEmpty)
        // …and evicted + on-screen reconstructs every line, in order, once.
        let reconstructed = (evicted + store.entries(in: .captions)).map(\.sourceText)
        #expect(reconstructed == (0..<700).map { "line \($0)" })
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

    @Test func targetSwapOnlyAffectsNewEntries() {
        let store = CaptionStore()
        let oldDirection = LanguagePair(source: .english, target: .chinese)
        let newDirection = LanguagePair(source: .english, target: .japanese)

        store.applyVolatile(text: "first", direction: oldDirection)
        let first = store.finalizeActive(text: "first", direction: oldDirection)
        store.setDraft("第一", for: first!.id)

        store.applyVolatile(text: "second", direction: newDirection)
        let second = store.finalizeActive(text: "second", direction: newDirection)

        #expect(store.entry(for: first!.id)?.direction == oldDirection)
        #expect(store.entry(for: first!.id)?.displayTranslation == "第一")
        #expect(store.entry(for: second!.id)?.direction == newDirection)
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

    @Test func splitEntriesPreserveRelativeTimestamps() throws {
        let store = CaptionStore()
        store.applyVolatile(text: "hello no", direction: enToZh)

        let entries = store.finalizeActiveSplit(
            parts: [
                (text: "hello", speaker: 0, offset: 0),
                (text: "no", speaker: 1, offset: 2.5),
            ],
            direction: enToZh)

        #expect(entries.count == 2)
        let first = try #require(entries.first)
        let second = try #require(entries.last)
        #expect(abs(second.createdAt.timeIntervalSince(first.createdAt) - 2.5) < 0.01)
    }

    @Test func segmentsGroupAndRecomputeAfterMutation() {
        let store = CaptionStore()
        let direction = LanguagePair(source: .english, target: .english)
        store.finalizeActive(text: "first", direction: direction)
        let firstCount = store.segments().count
        #expect(firstCount == 1)

        store.finalizeActive(text: "second", direction: direction)
        #expect(store.segments().reduce(0) { $0 + $1.entries.count } == 2)
    }

    @Test func segmentsCacheReturnsEqualResultWithoutMutation() {
        let store = CaptionStore()
        let direction = LanguagePair(source: .english, target: .english)
        store.finalizeActive(text: "hello", direction: direction)
        #expect(store.segments() == store.segments())
    }
}
