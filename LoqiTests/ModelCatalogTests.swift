import Foundation
import Testing

@testable import Loqi

/// Catalog shape guards. The summary lineup is the 2B (vision) plus the
/// standard text-only Bonsai tier; the live tiers (0.8B, LFM2.5) never
/// appear in it — live and summary roles are fully split. (History: a
/// TokenRing crash on 2-D VLM prompts was briefly misattributed to
/// Qwen3.5 itself; the fix lives in LLMService.FlattenedPromptProcessor.)
struct ModelCatalogTests {
    @Test func defaultIsQwen35() {
        #expect(ModelCatalog.default.id == ModelCatalog.qwen35_2b.id)
    }

    @Test func defaultLineupIsQwen2BAndBonsai() {
        #expect(defaultSelectableModelsForTests().map(\.id) == [
            ModelCatalog.qwen35_2b.id,
            ModelCatalog.bonsai8b.id,
        ])
        // Bonsai is text-only; the vision route depends on this staying false.
        #expect(ModelCatalog.bonsai8b.supportsVision == false)
    }

    @Test func knownIdsResolveToThemselves() {
        for option in defaultSelectableModelsForTests() {
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

    @Test func normalizationSnapsFastTierSummaryPickToDefault() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Migration for existing users: 0.8B used to be a summary pick.
        defaults.set(ModelCatalog.qwen35_0_8b.id, forKey: "model.id")
        ModelCatalog.normalizeStoredSelection(defaults)
        #expect(defaults.string(forKey: "model.id") == ModelCatalog.default.id)
    }

    @Test func normalizationLeavesBonsaiPickAlone() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(ModelCatalog.bonsai8b.id, forKey: "model.id")
        ModelCatalog.normalizeStoredSelection(defaults)
        #expect(defaults.string(forKey: "model.id") == ModelCatalog.bonsai8b.id)
    }

    @Test func liveModelIsTheFastTier() {
        #expect(ModelCatalog.liveModel.id == ModelCatalog.qwen35_0_8b.id)
        // Live tier must fit beside SenseVoice — strictly lighter than 2B.
        #expect(ModelCatalog.liveModel.requiredHeadroom
            < ModelCatalog.qwen35_2b.requiredHeadroom)
    }

    @Test func summaryModelFollowsUserPick() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ModelCatalog.qwen35_0_8b.id, forKey: "model.id")
        // summaryModel reads `current`, which reads standard defaults; assert
        // the relationship via option(for:) instead of mutating standard.
        #expect(ModelCatalog.summaryModel.id == ModelCatalog.current.id)
    }

    @Test func lfm2CandidateIsTextOnlyAndLighterThanLiveModel() {
        #expect(ModelCatalog.lfm2_5_230m.supportsVision == false)
        #expect(ModelCatalog.lfm2_5_230m.requiredHeadroom
            < ModelCatalog.liveModel.requiredHeadroom)
    }

    /// A model whose headroom sits below the memory-shed floor can be
    /// admitted into the shed zone: it loads at ~350 MB free, the next
    /// critical-pressure event unloads it, the next silence gap reloads
    /// it — the exact thrash loop the pressure handler exists to prevent.
    @Test @MainActor func everyTierClearsTheMemoryShedFloor() {
        let tiers = [
            ModelCatalog.qwen35_2b, ModelCatalog.qwen35_0_8b,
            ModelCatalog.bonsai8b, ModelCatalog.lfm2_5_230m,
        ]
        for tier in tiers {
            #expect(tier.requiredHeadroom > CaptionPipeline.memoryShedFloor)
        }
    }

    @Test func liveTiersNeverAppearInSummaryLineup() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Even with the live-refine flag on, live tiers stay out.
        defaults.set(true, forKey: "model.liveRefineLFM2Enabled")
        let ids = ModelCatalog.availableModels(defaults: defaults).map(\.id)
        #expect(!ids.contains(ModelCatalog.qwen35_0_8b.id))
        #expect(!ids.contains(ModelCatalog.lfm2_5_230m.id))
        #expect(ids.contains(ModelCatalog.bonsai8b.id))
    }

    @Test func normalizationDropsLFM2EvenWhenFlagEnabled() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "model.liveRefineLFM2Enabled")
        defaults.set(ModelCatalog.lfm2_5_230m.id, forKey: "model.id")
        ModelCatalog.normalizeStoredSelection(defaults)
        #expect(defaults.string(forKey: "model.id") == ModelCatalog.default.id)
    }

    @Test func liveRefineModelDefaultsToLiveModelTier() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ModelCatalog.liveRefineModel(defaults).id == ModelCatalog.liveModel.id)
    }

    @Test func liveRefineModelSwapsToLFM2WhenFlagEnabled() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "model.liveRefineLFM2Enabled")
        #expect(ModelCatalog.liveRefineModel(defaults).id == ModelCatalog.lfm2_5_230m.id)
        // liveModel itself must stay the vision-capable fixed tier.
        #expect(ModelCatalog.liveModel.id == ModelCatalog.qwen35_0_8b.id)
    }

}

private func defaultSelectableModelsForTests() -> [ModelOption] {
    let suite = "ModelCatalogTests.default.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    return ModelCatalog.availableModels(defaults: defaults)
}
