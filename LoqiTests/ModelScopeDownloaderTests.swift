import Foundation
import Testing
@testable import Loqi

/// Tests the downloader's pure logic: pattern filtering and manifest-based
/// snapshot validation. Network paths are exercised on-device.
struct ModelScopeDownloaderTests {
    let downloader = ModelScopeDownloader()

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func patternMatching() {
        #expect(downloader.matches("model.safetensors", patterns: ["*.safetensors"]))
        #expect(downloader.matches("sub/dir/model.safetensors", patterns: ["*.safetensors"]))
        #expect(downloader.matches("config.json", patterns: ["*.safetensors", "*.json"]))
        #expect(!downloader.matches("README.md", patterns: ["*.safetensors", "*.json"]))
        #expect(downloader.matches("anything.bin", patterns: []))
    }

    @Test func manifestRoundTripValidates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("hello world".utf8)
        try payload.write(to: dir.appending(path: "config.json"))
        let files = [ModelScopeDownloader.FileEntry(
            path: "config.json", size: Int64(payload.count))]

        try downloader.writeManifest(files, to: dir)
        #expect(downloader.isValidSnapshot(dir))
    }

    @Test func manifestCatchesTruncatedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("short".utf8).write(to: dir.appending(path: "weights.bin"))
        let files = [ModelScopeDownloader.FileEntry(path: "weights.bin", size: 9999)]
        try downloader.writeManifest(files, to: dir)
        #expect(!downloader.isValidSnapshot(dir))
    }

    @Test func manifestCatchesMissingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [ModelScopeDownloader.FileEntry(path: "gone.bin", size: 10)]
        try downloader.writeManifest(files, to: dir)
        #expect(!downloader.isValidSnapshot(dir))
    }

    @Test func emptyDirectoryIsInvalid() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!downloader.isValidSnapshot(dir))
    }
}
