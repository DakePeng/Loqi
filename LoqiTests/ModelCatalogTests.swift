import Foundation
import Testing

@testable import Loqi

/// Catalog shape guards. Qwen3.5 is natively multimodal — every tier
/// carries the vision tower, so there is no separate photo model and the
/// older Qwen3 tiers are gone. (History: a TokenRing crash on 2-D VLM
/// prompts was briefly misattributed to Qwen3.5 itself; the fix lives in
/// LLMService.FlattenedPromptProcessor.)
struct ModelCatalogTests {
    @Test func defaultIsQwen35() {
        #expect(ModelCatalog.default.id == ModelCatalog.qwen35_2b.id)
    }

    @Test func lineupIsAllQwen35() {
        #expect(ModelCatalog.all.map(\.id) == [
            ModelCatalog.qwen35_2b.id,
            ModelCatalog.qwen35_0_8b.id,
        ])
    }

    @Test func everyTierSupportsVision() {
        #expect(ModelCatalog.all.allSatisfy { $0.supportsVision })
    }

    @Test func knownIdsResolveToThemselves() {
        for option in ModelCatalog.all {
            #expect(ModelCatalog.option(for: option.id).id == option.id)
        }
    }

    @Test func unknownIdResolvesToDefault() {
        #expect(ModelCatalog.option(for: "mlx-community/Qwen3-1.7B-4bit").id
            == ModelCatalog.default.id)
    }

    @Test func normalizationSnapsRemovedTierToDefault() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("mlx-community/Qwen3-VL-2B-Instruct-4bit", forKey: "model.id")
        ModelCatalog.normalizeStoredSelection(defaults)
        #expect(defaults.string(forKey: "model.id") == ModelCatalog.default.id)
    }

    @Test func normalizationLeavesLiveSelectionsAlone() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(ModelCatalog.qwen35_0_8b.id, forKey: "model.id")
        ModelCatalog.normalizeStoredSelection(defaults)
        #expect(defaults.string(forKey: "model.id") == ModelCatalog.qwen35_0_8b.id)
    }
}
