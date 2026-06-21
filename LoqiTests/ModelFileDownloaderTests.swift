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
}
