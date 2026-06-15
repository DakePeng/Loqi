import Foundation
import Testing

@testable import Loqi

struct HotwordTests {
    // MARK: Codable back-compat — `aliases` must stay optional

    /// Pre-alias files (no "aliases" key) must keep decoding: a throwing
    /// decode would silently wipe the user's hotwords via the store's
    /// `try?` load. The fixture pins the real on-disk shape — Swift encodes
    /// `[AppLanguage: String]` as a flat key/value array, not a JSON object.
    @Test func legacyJSONWithoutAliasesDecodes() throws {
        let json = """
        [{"id":"6F1B6E1B-2F5C-4F3A-9D0A-111111111111","term":"Zhipeng",\
        "renderings":["chinese","志鹏"],"note":"person name"}]
        """
        let decoded = try JSONDecoder().decode([Hotword].self, from: Data(json.utf8))
        #expect(decoded.first?.term == "Zhipeng")
        #expect(decoded.first?.renderings[.chinese] == "志鹏")
        #expect(decoded.first?.aliases == nil)
    }

    /// nil aliases encode as an absent key, so files written by this version
    /// stay readable by pre-alias app versions — and decoding our own
    /// output exercises the missing-key path format-agnostically.
    @Test func nilAliasesRoundTripWithoutTheKey() throws {
        let legacy = Hotword(
            term: "Zhipeng", renderings: [.chinese: "志鹏"], note: "person name")
        let data = try JSONEncoder().encode([legacy])
        #expect(!String(decoding: data, as: UTF8.self).contains("aliases"))
        let decoded = try JSONDecoder().decode([Hotword].self, from: data)
        #expect(decoded.first?.aliases == nil)
    }

    @Test func aliasesRoundTrip() throws {
        let hotword = Hotword(term: "Robert Smith", aliases: ["Bobby", "小罗"])
        let data = try JSONEncoder().encode([hotword])
        let decoded = try JSONDecoder().decode([Hotword].self, from: data)
        #expect(decoded.first?.aliases == ["Bobby", "小罗"])
    }

    // MARK: Forms

    @Test func recognitionFormsIncludeAliasesDeduped() {
        let hotword = Hotword(
            term: "Robert Smith", aliases: ["Bobby", "Robert Smith", ""])
        #expect(hotword.recognitionForms(for: .english) == ["Robert Smith", "Bobby"])
    }

    @Test func fixupPairsMapAliasesToThemselves() {
        let hotword = Hotword(
            term: "Robert Smith",
            renderings: [.chinese: "罗伯特"],
            aliases: ["Bobby"])
        let chinese = hotword.fixupPairs(for: .chinese)
        #expect(chinese.map(\.form) == ["罗伯特", "Robert Smith", "Bobby"])
        #expect(chinese.map(\.replacement) == ["罗伯特", "罗伯特", "Bobby"])
    }

    @Test func aliasEqualToTermKeepsCanonicalMapping() {
        let hotword = Hotword(
            term: "Qwen", renderings: [.chinese: "千问"], aliases: ["Qwen", "Q"])
        let pairs = hotword.fixupPairs(for: .chinese)
        // "Qwen" already maps to the canonical rendering; the duplicate
        // alias must not downgrade it to alias→alias.
        #expect(pairs.map(\.form) == ["千问", "Qwen", "Q"])
        #expect(pairs.map(\.replacement) == ["千问", "千问", "Q"])
    }
}
