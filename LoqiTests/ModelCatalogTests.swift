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

    @Test func defaultLineupIgnoresStandardBonsaiFlag() {
        let oldValue = UserDefaults.standard.object(forKey: "model.bonsaiEnabled")
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: "model.bonsaiEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "model.bonsaiEnabled")
            }
        }

        UserDefaults.standard.set(true, forKey: "model.bonsaiEnabled")

        #expect(defaultSelectableModelsForTests().map(\.id) == [
            ModelCatalog.qwen35_2b.id,
            ModelCatalog.qwen35_0_8b.id,
        ])
    }

    @Test func lineupIsAllQwen35() {
        #expect(defaultSelectableModelsForTests().map(\.id) == [
            ModelCatalog.qwen35_2b.id,
            ModelCatalog.qwen35_0_8b.id,
        ])
    }

    @Test func everyTierSupportsVision() {
        #expect(defaultSelectableModelsForTests().allSatisfy { $0.supportsVision })
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

    @Test func normalizationLeavesLiveSelectionsAlone() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(ModelCatalog.qwen35_0_8b.id, forKey: "model.id")
        ModelCatalog.normalizeStoredSelection(defaults)
        #expect(defaults.string(forKey: "model.id") == ModelCatalog.qwen35_0_8b.id)
    }

    @Test func bonsaiAppearsOnlyWhenFlagEnabled() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Off by default.
        #expect(!ModelCatalog.availableModels(defaults: defaults)
            .contains { $0.id == ModelCatalog.bonsai8b.id })

        defaults.set(true, forKey: "model.bonsaiEnabled")
        let on = ModelCatalog.availableModels(defaults: defaults)
        #expect(on.contains { $0.id == ModelCatalog.bonsai8b.id })
        // Bonsai is text-only; the vision route depends on this staying false.
        #expect(ModelCatalog.bonsai8b.supportsVision == false)
    }

    @Test func normalizationDropsBonsaiWhenFlagDisabled() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(ModelCatalog.bonsai8b.id, forKey: "model.id")  // flag stays off
        ModelCatalog.normalizeStoredSelection(defaults)
        #expect(defaults.string(forKey: "model.id") == ModelCatalog.default.id)
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

    @Test func lfm2AppearsInSummaryLineupOnlyWhenFlagEnabled() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Off by default — and independent of the Bonsai flag.
        defaults.set(true, forKey: "model.bonsaiEnabled")
        #expect(!ModelCatalog.availableModels(defaults: defaults)
            .contains { $0.id == ModelCatalog.lfm2_5_230m.id })

        defaults.set(true, forKey: "model.liveRefineLFM2Enabled")
        #expect(ModelCatalog.availableModels(defaults: defaults)
            .contains { $0.id == ModelCatalog.lfm2_5_230m.id })
    }

    @Test func normalizationDropsLFM2WhenFlagDisabled() {
        let suite = "ModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(ModelCatalog.lfm2_5_230m.id, forKey: "model.id")  // flag stays off
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
