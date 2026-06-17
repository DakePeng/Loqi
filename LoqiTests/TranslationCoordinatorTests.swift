import Testing
@testable import Loqi

@MainActor
struct TranslationCoordinatorTests {
    let zhToJa = LanguagePair(source: .chinese, target: .japanese)
    let enToZh = LanguagePair(source: .english, target: .chinese)

    @Test func directPairRegistersItself() async {
        let coordinator = TranslationCoordinator(needsPivot: { _ in false })
        await coordinator.setDirections([enToZh])
        #expect(coordinator.requiredDirections == [enToZh])
    }

    @Test func pivotPairExpandsIntoEnglishLegs() async {
        let coordinator = TranslationCoordinator(needsPivot: { pair in
            pair.source != .english && pair.target != .english
        })
        await coordinator.setDirections([zhToJa])
        #expect(coordinator.requiredDirections == [
            LanguagePair(source: .chinese, target: .english),
            LanguagePair(source: .english, target: .japanese),
        ])
    }

    @Test func mixedDirectionsExpandCorrectly() async {
        let coordinator = TranslationCoordinator(needsPivot: { pair in
            pair.source != .english && pair.target != .english
        })
        await coordinator.setDirections([enToZh, zhToJa])
        #expect(coordinator.requiredDirections.contains(enToZh))
        #expect(coordinator.requiredDirections.contains(
            LanguagePair(source: .chinese, target: .english)))
        #expect(coordinator.requiredDirections.contains(
            LanguagePair(source: .english, target: .japanese)))
        #expect(!coordinator.requiredDirections.contains(zhToJa))
    }

    @Test func addDirectionIsAdditiveAndIdempotent() async {
        let coordinator = TranslationCoordinator(needsPivot: { _ in false })
        await coordinator.setDirections([enToZh])
        await coordinator.addDirection(enToZh.reversed)
        await coordinator.addDirection(enToZh.reversed)
        #expect(coordinator.requiredDirections == [enToZh, enToZh.reversed])
    }

    @Test func addDirectionExpandsPivots() async {
        let coordinator = TranslationCoordinator(needsPivot: { pair in
            pair.source != .english && pair.target != .english
        })
        await coordinator.setDirections([enToZh])
        await coordinator.addDirection(zhToJa)
        #expect(coordinator.requiredDirections.contains(
            LanguagePair(source: .english, target: .japanese)))
        #expect(!coordinator.requiredDirections.contains(zhToJa))
    }

    @Test func addDirectionRestoresCachedPivotAfterDirectionsWereCleared() async {
        let coordinator = TranslationCoordinator(needsPivot: { pair in
            pair.source != .english && pair.target != .english
        })
        let zhToEn = LanguagePair(source: .chinese, target: .english)
        let enToJa = LanguagePair(source: .english, target: .japanese)

        await coordinator.setDirections([zhToJa])
        await coordinator.setDirections([])
        await coordinator.addDirection(zhToJa)

        #expect(coordinator.requiredDirections == [zhToEn, enToJa])
    }
}
