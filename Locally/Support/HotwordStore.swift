import Foundation
import Observation

/// User-managed hotword list with JSON persistence. The pipeline snapshots
/// `matcher` per utterance; edits notify `onChange` so live ASR sessions can
/// refresh their contextual strings.
@MainActor
@Observable
final class HotwordStore {
    private(set) var hotwords: [Hotword] = []

    /// Set by CaptionPipeline; fired after any mutation.
    @ObservationIgnored var onChange: (() -> Void)?

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "hotwords.json")
    }

    init() {
        load()
    }

    /// Immutable snapshot for use off the main actor.
    var matcher: HotwordMatcher { HotwordMatcher(hotwords: hotwords) }

    /// Strings to bias ASR recognition for one language. Apple guidance for
    /// contextual strings: keep the list modest.
    func biasStrings(for language: AppLanguage) -> [String] {
        var seen = Set<String>()
        var strings: [String] = []
        for hotword in hotwords {
            for form in hotword.recognitionForms(for: language)
            where seen.insert(form).inserted {
                strings.append(form)
            }
        }
        return Array(strings.prefix(100))
    }

    // MARK: Mutations

    func add(_ hotword: Hotword) {
        hotwords.append(hotword)
        persist()
    }

    func update(_ hotword: Hotword) {
        guard let index = hotwords.firstIndex(where: { $0.id == hotword.id }) else { return }
        hotwords[index] = hotword
        persist()
    }

    func remove(at offsets: IndexSet) {
        hotwords.remove(atOffsets: offsets)
        persist()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([Hotword].self, from: data)
        else { return }
        hotwords = decoded
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(hotwords) {
            try? data.write(to: Self.fileURL)
        }
        onChange?()
    }
}
