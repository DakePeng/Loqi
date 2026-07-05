import Foundation
import Testing

@testable import Loqi

/// Manifest guards for the sherpa-onnx diarization bundle (pyannote
/// segmentation-3.0 + 3D-Speaker CAM++ zh/en): file layout, sizes, and
/// per-source URL paths — the dual-source pattern Qwen3ASRModelStore uses.
struct DiarizerModelStoreTests {
    @Test func manifestListsSegmentationAndEmbedding() {
        let names = DiarizerModelStore.files.map(\.name)
        #expect(names.count == 2)
        #expect(names.contains("pyannote-segmentation-3-0.onnx"))
        #expect(names.contains(
            "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"))
        for file in DiarizerModelStore.files {
            #expect(file.minBytes > 0)
            #expect(file.minBytes <= file.expectedBytes)
        }
    }

    @Test func expectedSizesMatchTheVerifiedUploads() {
        let bySuffix = { (suffix: String) in
            DiarizerModelStore.files.first { $0.name.hasSuffix(suffix) }!
        }
        // content-length verified against Hugging Face 2026-07-05.
        #expect(bySuffix("segmentation-3-0.onnx").expectedBytes == 5_992_913)
        #expect(bySuffix("common_advanced.onnx").expectedBytes == 28_281_164)
        #expect(DiarizerModelStore.totalExpectedBytes == 5_992_913 + 28_281_164)
    }

    @Test func pathsResolvePerSource() {
        for file in DiarizerModelStore.files {
            #expect(file.path(for: .huggingFace).hasPrefix("csukuangfj/"))
            // Community mirrors, verified byte-identical to the HF uploads
            // (URLs + sizes checked 2026-07-05).
            #expect(file.path(for: .modelScope).hasPrefix("models/"))
            #expect(file.path(for: .modelScope).contains("/resolve/master/"))
            #expect(file.path(for: .modelScope).hasSuffix(".onnx"))
        }
    }

    @Test func legacyHFMirrorSourceMigratesToModelScope() {
        let suite = "DiarizerModelStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Pre-sherpa China-mainland onboarding wrote the retired value.
        defaults.set("hfMirror", forKey: DiarizerModelStore.sourceDefaultsKey)
        DiarizerModelStore.migrateStoredSource(defaults: defaults)
        #expect(defaults.string(forKey: DiarizerModelStore.sourceDefaultsKey)
            == ASRModelSource.modelScope.rawValue)

        // Valid values pass through untouched.
        defaults.set(ASRModelSource.huggingFace.rawValue,
                     forKey: DiarizerModelStore.sourceDefaultsKey)
        DiarizerModelStore.migrateStoredSource(defaults: defaults)
        #expect(defaults.string(forKey: DiarizerModelStore.sourceDefaultsKey)
            == ASRModelSource.huggingFace.rawValue)
    }

    @Test func clusteringSplitsAutoFromExplicitCounts() {
        // Every explicit pick the import sheet offers (2...6) forces that
        // exact cluster count — sherpa's preferred known-count mode.
        for count in 2...6 {
            let config = VoiceprintService.clustering(forPickerValue: count)
            #expect(config.numClusters == count)
        }
        // "Auto" (-1) discovers the count by distance threshold.
        let auto = VoiceprintService.clustering(forPickerValue: -1)
        #expect(auto.numClusters == -1)
        #expect(auto.threshold > 0)
    }
}
