import Foundation
import Testing
@testable import Loqi

struct RecordingIntentsTests {
    @Test func missingDefaultsFallBackToEnglishTranscribeOnly() {
        let direction = StartRecordingIntent.resolveDirection(
            sourceRaw: nil, translationRaw: nil)
        #expect(direction == LanguagePair(source: .english, target: .english))
    }

    @Test func emptyTranslationMeansTranscribeOnly() {
        let direction = StartRecordingIntent.resolveDirection(
            sourceRaw: "chinese", translationRaw: "")
        #expect(direction == LanguagePair(source: .chinese, target: .chinese))
    }

    @Test func storedPairResolvesAsIs() {
        let direction = StartRecordingIntent.resolveDirection(
            sourceRaw: "chinese", translationRaw: "english")
        #expect(direction == LanguagePair(source: .chinese, target: .english))
    }

    @Test func garbageRawValuesFallBackSafely() {
        let direction = StartRecordingIntent.resolveDirection(
            sourceRaw: "klingon", translationRaw: "elvish")
        #expect(direction == LanguagePair(source: .english, target: .english))
    }

    @Test func autoSourceResolvesToRoute() {
        let route = StartRecordingIntent.resolveRoute(
            sourceRaw: "auto", translationRaw: "japanese")
        #expect(route.source == .auto)
        #expect(route.target == .japanese)
    }

    @Test func autoDirectionFallsBackSafelyForLegacyCallers() {
        let direction = StartRecordingIntent.resolveDirection(
            sourceRaw: "auto", translationRaw: "korean")
        #expect(direction.source == (AppLanguage.devicePreferred ?? .english))
        #expect(direction.target == .korean)
    }
}

struct RecordingSharedStateTests {
    @Test func nilOrCorruptDataDecodesToNotRunning() {
        #expect(RecordingSharedState.decode(nil)
            == RecordingSharedState(isRunning: false, startedAt: nil))
        #expect(RecordingSharedState.decode(Data("junk".utf8))
            == RecordingSharedState(isRunning: false, startedAt: nil))
    }

    @Test func roundTrips() throws {
        let state = RecordingSharedState(
            isRunning: true, startedAt: Date(timeIntervalSince1970: 1_000_000))
        let data = try JSONEncoder().encode(state)
        #expect(RecordingSharedState.decode(data) == state)
    }
}

struct RecordingActivityAttributesTests {
    @Test func contentStateRoundTrips() throws {
        let state = RecordingActivityAttributes.ContentState(
            statusLabel: "Recording", isPaused: false)
        let decoded = try JSONDecoder().decode(
            RecordingActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded.hashValue == state.hashValue)
    }
}
