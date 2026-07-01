import Foundation
import Testing
@testable import Loqi

struct ModelFileDownloaderTests {
    @Test func largeModelFilesUseBackgroundTransferOnIOS() {
        #if os(iOS)
        #expect(ModelFileDownloader.mode(forExpectedBytes: 239_233_841) == .backgroundURLSession)
        #else
        #expect(ModelFileDownloader.mode(forExpectedBytes: 239_233_841) == .foregroundSegmented)
        #endif
    }

    @Test func smallModelFilesStayOnForegroundTransfer() {
        #expect(ModelFileDownloader.mode(forExpectedBytes: 320_000) == .foregroundSegmented)
    }

    @Test func thresholdSizedModelFilesStayOnForegroundTransfer() {
        #expect(ModelFileDownloader.mode(forExpectedBytes: 8 << 20) == .foregroundSegmented)
    }

    @Test func backgroundTransferIDIsStableForURLAndDestination() {
        #if os(iOS)
        let url = URL(string: "https://huggingface.co/org/model/resolve/main/weights.safetensors")!
        let destination = URL(fileURLWithPath: "/tmp/Loqi/../Loqi/model/weights.safetensors")

        #expect(BackgroundModelDownloader.transferID(url: url, destination: destination) == BackgroundModelDownloader.transferID(url: url, destination: destination.standardizedFileURL))
        #expect(BackgroundModelDownloader.transferID(url: url, destination: destination) != BackgroundModelDownloader.transferID(url: url, destination: destination.deletingLastPathComponent().appending(path: "other.safetensors")))
        #endif
    }

    @Test func backgroundTransferCanAdoptLegacyPendingTaskID() {
        #if os(iOS)
        let url = URL(string: "https://huggingface.co/org/model/resolve/main/weights.safetensors")!
        let destination = URL(fileURLWithPath: "/tmp/Loqi/../Loqi/model/weights.safetensors")
        let legacyID = UUID().uuidString
        let otherID = UUID().uuidString
        let pending = [
            legacyID: destination.path,
            otherID: destination.deletingLastPathComponent().appending(path: "other.safetensors").path,
        ]
        let tasks: [(id: String, url: URL?)] = [
            (otherID, url),
            (legacyID, url),
        ]

        #expect(BackgroundModelDownloader.legacyTransferID(
            url: url,
            destination: destination.standardizedFileURL,
            pendingDestinations: pending,
            taskURLs: tasks) == legacyID)
        #expect(BackgroundModelDownloader.legacyTransferID(
            url: url.appending(queryItems: [URLQueryItem(name: "v", value: "2")]),
            destination: destination.standardizedFileURL,
            pendingDestinations: pending,
            taskURLs: tasks) == nil)
        #endif
    }

    @Test func backgroundCancellationKeepsResumeData() throws {
        #if os(iOS)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appending(path: "Loqi/Support/ModelFileDownloader.swift"),
            encoding: .utf8)

        #expect(text.contains("cancel(byProducingResumeData:"))
        #expect(text.contains("writeResumeData"))
        #expect(text.contains("let wasCancelled = cancelled.contains(id)"))
        #endif
    }

    @Test func failedBackgroundTransfersKeepResumeData() throws {
        #if os(iOS)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appending(path: "Loqi/Support/ModelFileDownloader.swift"),
            encoding: .utf8)

        #expect(text.contains("NSURLSessionDownloadTaskResumeData"))
        #expect(text.contains("preserveResumeData"))
        #endif
    }

    @Test func foregroundModeRemainsAvailableForTinyFiles() async throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appending(path: "tiny.bin")
        let source = dir.appending(path: "source.bin")
        try Data("ok".utf8).write(to: source)

        try await ModelFileDownloader.download(
            url: source,
            to: destination,
            expectedBytes: 2
        ) { _ in }

        #expect((try Data(contentsOf: destination)) == Data("ok".utf8))
    }

    @Test func localFileChecksumMismatchDoesNotReplaceDestination() async throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appending(path: "model.bin")
        let source = dir.appending(path: "source.bin")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: source)

        do {
            try await ModelFileDownloader.download(
                url: source,
                to: destination,
                expectedBytes: 3,
                sha256: String(repeating: "0", count: 64)
            ) { _ in }
        } catch SegmentedDownloader.Failure.checksumMismatch {
            #expect((try Data(contentsOf: destination)) == Data("old".utf8))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
            return
        }

        Issue.record("Expected checksum mismatch")
    }

    @Test func modelStoresNoLongerCallSegmentedDownloaderDirectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            root.appending(path: "Loqi/Pipeline/ASR/SenseVoiceModelStore.swift"),
            root.appending(path: "Loqi/Pipeline/ASR/Qwen3ASRModelStore.swift"),
            root.appending(path: "Loqi/Pipeline/Refinement/ModelScopeDownloader.swift"),
        ]

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("SegmentedDownloader().download("), "\(file.lastPathComponent) still bypasses ModelFileDownloader")
        }
    }
}
