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
            #expect(file.path(for: .modelScope)
                .hasPrefix("models/zengshuishui/speaker-diarization-onnx/"))
            #expect(file.path(for: .modelScope).hasSuffix(file.name))
        }
    }

    @Test func clusteringSplitsAutoFromExplicitCounts() {
        for count in 2...VoiceprintService.maxSupportedSpeakers {
            let config = VoiceprintService.clustering(maxSpeakers: count)
            #expect(config.numClusters == count)
        }
        // "Auto" arrives as clusterCap(-1) == 8, above the explicit picker
        // ceiling: discover the count by distance threshold instead of
        // forcing eight clusters.
        let auto = VoiceprintService.clustering(maxSpeakers: 8)
        #expect(auto.numClusters == -1)
        #expect(auto.threshold > 0)
    }
}
