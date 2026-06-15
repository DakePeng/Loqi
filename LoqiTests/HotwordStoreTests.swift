import Foundation
import Testing

@testable import Loqi

@MainActor
struct HotwordStoreTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func isKnownMatchesTermRenderingAndAlias() {
        let store = HotwordStore(directory: makeTempDirectory())
        store.add(Hotword(
            term: "Robert Smith",
            renderings: [.chinese: "罗伯特"],
            aliases: ["Bobby"]))
        #expect(store.isKnown("robert smith"))
        #expect(store.isKnown("罗伯特"))
        #expect(store.isKnown(" bobby "))
        #expect(!store.isKnown("Carol"))
        #expect(!store.isKnown("  "))
    }

    @Test func captureIfNewAddsOnceAndSkipsKnown() {
        let store = HotwordStore(directory: makeTempDirectory())
        #expect(!store.captureIfNew(term: "   ", note: "person name"))
        #expect(store.captureIfNew(term: "Robert", note: "person name"))
        #expect(!store.captureIfNew(term: "ROBERT", note: "person name"))
        #expect(store.hotwords.map(\.term) == ["Robert"])
        #expect(store.hotwords[0].note == "person name")
    }

    @Test func enqueueSkipsKnownAndPendingDuplicates() {
        let store = HotwordStore(directory: makeTempDirectory())
        store.add(Hotword(term: "Known"))
        store.enqueueSuggestions([
            (term: "Known", note: ""),
            (term: "Fresh", note: "n"),
            (term: " fresh ", note: ""),
        ])
        #expect(store.pending.map(\.term) == ["Fresh"])
    }

    @Test func enqueueRespectsTheCap() {
        let store = HotwordStore(directory: makeTempDirectory())
        store.enqueueSuggestions((0..<30).map { (term: "Term\($0)", note: "") })
        #expect(store.pending.count == 20)
    }

    @Test func acceptPromotesAndRemoves() throws {
        let store = HotwordStore(directory: makeTempDirectory())
        store.enqueueSuggestions([(term: "Qwen", note: "model family")])
        let suggestion = try #require(store.pending.first)
        store.accept(suggestion)
        #expect(store.pending.isEmpty)
        #expect(store.hotwords.contains { $0.term == "Qwen" && $0.note == "model family" })
    }

    @Test func dismissRemovesWithoutAdding() throws {
        let store = HotwordStore(directory: makeTempDirectory())
        store.enqueueSuggestions([(term: "Qwen", note: "")])
        let suggestion = try #require(store.pending.first)
        store.dismiss(suggestion)
        #expect(store.pending.isEmpty)
        #expect(store.hotwords.isEmpty)
    }

    @Test func addingKnownTermPrunesPending() {
        let store = HotwordStore(directory: makeTempDirectory())
        store.enqueueSuggestions([(term: "Bobby", note: "")])
        // Speaker rename / manual add covering a pending term retires it.
        store.add(Hotword(term: "Robert", aliases: ["Bobby"]))
        #expect(store.pending.isEmpty)
    }

    @Test func pendingSurvivesReload() {
        let directory = makeTempDirectory()
        HotwordStore(directory: directory)
            .enqueueSuggestions([(term: "Qwen", note: "model")])
        let reloaded = HotwordStore(directory: directory)
        #expect(reloaded.pending.map(\.term) == ["Qwen"])
        #expect(reloaded.pending.map(\.note) == ["model"])
    }

    @Test func enqueueSetsSessionFieldsAndCreatedAt() {
        let store = HotwordStore(directory: makeTempDirectory())
        let sid = UUID()
        store.enqueueSuggestions(
            [(term: "Transformer", note: "arch")],
            sessionID: sid, sessionTitle: "AI Talk")
        #expect(store.pending.first?.sessionID == sid)
        #expect(store.pending.first?.sessionTitle == "AI Talk")
        #expect(store.pending.first?.createdAt != nil)
    }

    @Test func dismissAllRemovesOneSessionsGroup() {
        let store = HotwordStore(directory: makeTempDirectory())
        let s1 = UUID(), s2 = UUID()
        store.enqueueSuggestions(
            [(term: "A", note: ""), (term: "B", note: "")],
            sessionID: s1, sessionTitle: "Session 1")
        store.enqueueSuggestions(
            [(term: "C", note: "")],
            sessionID: s2, sessionTitle: "Session 2")
        store.dismissAll(sessionID: s1)
        #expect(store.pending.map(\.term) == ["C"])
    }

    @Test func retireStaleRemovesOldSuggestions() {
        let store = HotwordStore(directory: makeTempDirectory())
        store.enqueueSuggestions([(term: "Old", note: ""), (term: "New", note: "")])
        let now = Date()
        store.retireStale(now: now.addingTimeInterval(15 * 86400))
        #expect(store.pending.map(\.term) == [])
    }

    @Test func retireStaleKeepsRecentSuggestions() {
        let store = HotwordStore(directory: makeTempDirectory())
        store.enqueueSuggestions([(term: "Recent", note: "")])
        let now = Date()
        store.retireStale(now: now.addingTimeInterval(5 * 86400))
        #expect(store.pending.map(\.term) == ["Recent"])
    }

    @Test func retireStaleKeepsLegacyNilCreatedAt() throws {
        let directory = makeTempDirectory()
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111",\
        "term":"Legacy","note":"old item"}]
        """
        try Data(json.utf8).write(
            to: directory.appending(path: "hotword-suggestions.json"))
        let store = HotwordStore(directory: directory)
        #expect(store.pending.first?.createdAt == nil)
        store.retireStale(now: Date().addingTimeInterval(999 * 86400))
        #expect(store.pending.map(\.term) == ["Legacy"])
    }

    @Test func legacyHotwordsFileLoads() throws {
        let directory = makeTempDirectory()
        // Real pre-alias on-disk shape: renderings is a flat key/value
        // array (Swift's encoding for enum-keyed dictionaries).
        let json = """
        [{"id":"6F1B6E1B-2F5C-4F3A-9D0A-111111111111","term":"Zhipeng",\
        "renderings":["chinese","志鹏"],"note":"person name"}]
        """
        try Data(json.utf8).write(to: directory.appending(path: "hotwords.json"))
        let store = HotwordStore(directory: directory)
        #expect(store.hotwords.map(\.term) == ["Zhipeng"])
        #expect(store.hotwords.first?.renderings[.chinese] == "志鹏")
        #expect(store.hotwords.first?.aliases == nil)
    }
}
