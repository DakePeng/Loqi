import Foundation
import Testing
@testable import Locally

/// Tests the segmented downloader's pure logic: segment layout, the
/// Content-Range parser that segment validation hinges on, and resume-ledger
/// acceptance/rejection. Network paths are exercised on-device.
struct SegmentedDownloaderTests {
    let downloader = SegmentedDownloader()

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Layout

    @Test func layoutTilesTheFileExactly() {
        let total: Int64 = 239_233_841
        let segments = SegmentedDownloader.layout(
            total: total, connections: 4, minBytesPerConnection: 24 << 20)
        #expect(segments.count == 4)
        var cursor: Int64 = 0
        for segment in segments {
            #expect(segment.start == cursor)
            #expect(segment.written == 0)
            cursor += segment.length
        }
        #expect(cursor == total)
    }

    @Test func layoutKeepsSmallFilesWhole() {
        let segments = SegmentedDownloader.layout(
            total: 10 << 20, connections: 4, minBytesPerConnection: 24 << 20)
        #expect(segments.count == 1)
        #expect(segments[0].length == 10 << 20)
    }

    @Test func layoutCapsConnectionsByMinimumShare() {
        // 50MB at a 24MB floor supports only 2 connections, not 4.
        let segments = SegmentedDownloader.layout(
            total: 50 << 20, connections: 4, minBytesPerConnection: 24 << 20)
        #expect(segments.count == 2)
    }

    @Test func layoutOfNothingIsEmpty() {
        #expect(SegmentedDownloader.layout(
            total: 0, connections: 4, minBytesPerConnection: 24 << 20).isEmpty)
    }

    // MARK: Content-Range parsing

    @Test func parsesWellFormedContentRange() throws {
        let range = try #require(
            SegmentedDownloader.parseContentRange("bytes 1000-1999/1722271785"))
        #expect(range.start == 1000)
        #expect(range.end == 1999)
        #expect(range.total == 1_722_271_785)
    }

    @Test func rejectsMalformedContentRange() {
        // Wildcard forms mean the server can't be segmented on; inverted or
        // overflowing ranges mean it's lying.
        #expect(SegmentedDownloader.parseContentRange("bytes */1234") == nil)
        #expect(SegmentedDownloader.parseContentRange("bytes 0-0/*") == nil)
        #expect(SegmentedDownloader.parseContentRange("bytes 5-4/10") == nil)
        #expect(SegmentedDownloader.parseContentRange("bytes 0-10/10") == nil)
        #expect(SegmentedDownloader.parseContentRange("items 0-1/10") == nil)
        #expect(SegmentedDownloader.parseContentRange("") == nil)
    }

    @Test func acceptsBoundaryContentRange() throws {
        let range = try #require(SegmentedDownloader.parseContentRange("bytes 0-0/1"))
        #expect(range.total == 1)
    }

    // MARK: Resume ledger validation

    private func writeState(
        _ state: SegmentedDownloader.ResumeState, in dir: URL
    ) throws -> URL {
        let meta = dir.appending(path: "file.part.meta")
        try JSONEncoder().encode(state).write(to: meta)
        return meta
    }

    @Test func acceptsConsistentLedger() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = SegmentedDownloader.ResumeState(
            total: 100, sha256: "abc",
            segments: [
                .init(start: 0, length: 50, written: 50),
                .init(start: 50, length: 50, written: 10),
            ])
        let meta = try writeState(state, in: dir)
        let loaded = downloader.validResumeState(at: meta, partSize: 100, sha256: "abc")
        #expect(loaded == state)
    }

    @Test func rejectsLedgerWhenPartFileSizeDiffers() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = SegmentedDownloader.ResumeState(
            total: 100, sha256: nil,
            segments: [.init(start: 0, length: 100, written: 10)])
        let meta = try writeState(state, in: dir)
        #expect(downloader.validResumeState(at: meta, partSize: 50, sha256: nil) == nil)
    }

    @Test func rejectsLedgerWhenContentIdentityChanged() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = SegmentedDownloader.ResumeState(
            total: 100, sha256: "old-revision",
            segments: [.init(start: 0, length: 100, written: 10)])
        let meta = try writeState(state, in: dir)
        #expect(downloader.validResumeState(
            at: meta, partSize: 100, sha256: "new-revision") == nil)
    }

    @Test func rejectsLedgerWithGapsOrOverruns() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Gap between segments.
        let gappy = SegmentedDownloader.ResumeState(
            total: 100, sha256: nil,
            segments: [
                .init(start: 0, length: 40, written: 0),
                .init(start: 50, length: 50, written: 0),
            ])
        let gappyMeta = try writeState(gappy, in: dir)
        #expect(downloader.validResumeState(at: gappyMeta, partSize: 100, sha256: nil) == nil)

        // Written more than the segment holds.
        let overrun = SegmentedDownloader.ResumeState(
            total: 100, sha256: nil,
            segments: [.init(start: 0, length: 100, written: 101)])
        let overrunMeta = try writeState(overrun, in: dir)
        #expect(downloader.validResumeState(at: overrunMeta, partSize: 100, sha256: nil) == nil)
    }

    @Test func rejectsMissingOrGarbageLedger() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appending(path: "nope.part.meta")
        #expect(downloader.validResumeState(at: missing, partSize: 100, sha256: nil) == nil)

        let garbage = dir.appending(path: "file.part.meta")
        try Data("not json".utf8).write(to: garbage)
        #expect(downloader.validResumeState(at: garbage, partSize: 100, sha256: nil) == nil)
    }

    // MARK: Hashing

    @Test func sha256MatchesKnownDigest() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appending(path: "data.bin")
        try Data("hello world".utf8).write(to: file)
        let digest = try await SegmentedDownloader.sha256Hex(of: file)
        #expect(digest == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }
}
