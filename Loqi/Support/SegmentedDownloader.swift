import CryptoKit
import Foundation

/// Multi-connection downloader for large model files.
///
/// A single TCP stream to a far CDN is capped by per-connection throttling
/// and cross-border packet loss — that, not the local link, is why a 1.7GB
/// model crawls at 1-2MB/s. Fetching several byte ranges in parallel
/// multiplies throughput by roughly the connection count. ModelScope's LFS
/// CDN and Hugging Face both answer bounded Range requests with a proper
/// 206 + Content-Range (verified 2026-06, including through the 302 to
/// cdn-lfs-cn-1.modelscope.cn — URLSession re-sends Range on redirect).
///
/// Each segment runs on its own ephemeral URLSession: HTTP/2 would
/// multiplex requests from a shared session onto ONE connection, which
/// silently re-creates the single-stream bottleneck on lossy paths.
///
/// On-disk layout while a download is live:
///   <file>.part        preallocated to full size; segments write at offsets
///   <file>.part.meta   JSON ledger of per-segment progress, flushed every
///                      few MB — an app relaunch resumes instead of restarting
/// Completion renames .part into place and removes the ledger.
struct SegmentedDownloader: Sendable {
    /// Parallel connections for files large enough to split.
    var connections = 4
    /// Below this per-connection share, extra connections only add TLS
    /// handshakes. Files under twice this size download as one plain stream.
    var minBytesPerConnection: Int64 = 24 << 20

    enum Failure: LocalizedError {
        case badStatus(Int)
        case mismatchedRange(String)
        case truncated
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): "Server answered \(code)."
            case .mismatchedRange(let detail): "Server returned the wrong byte range (\(detail))."
            case .truncated: "The connection ended before the file was complete."
            case .checksumMismatch: "The downloaded file failed its integrity check."
            }
        }
    }

    /// One contiguous byte range of the file and how much of it is on disk.
    struct Segment: Codable, Equatable {
        var start: Int64
        var length: Int64
        var written: Int64
    }

    /// The persisted ledger. `sha256` ties a resume to the exact content the
    /// download started with; a catalog/revision change starts over instead
    /// of stitching two revisions together.
    struct ResumeState: Codable, Equatable {
        var total: Int64
        var sha256: String?
        var segments: [Segment]
    }

    /// Download `url` into `destination`, atomically via the .part file.
    /// `expectedBytes` decides plain-vs-segmented and need only be
    /// approximate — the authoritative size comes from the server's
    /// Content-Range. `onBytes` reports cumulative bytes on disk.
    func download(
        url: URL,
        to destination: URL,
        expectedBytes: Int64,
        sha256: String? = nil,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let part = destination.appendingPathExtension("part")
        let meta = part.appendingPathExtension("meta")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if expectedBytes < minBytesPerConnection * 2 {
            try await plainStream(url, to: part, onBytes: onBytes)
        } else {
            try await segmentedStream(
                url, part: part, meta: meta, sha256: sha256, onBytes: onBytes)
        }

        try? FileManager.default.removeItem(at: meta)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)
    }

    // MARK: Segmented path

    private func segmentedStream(
        _ url: URL,
        part: URL,
        meta: URL,
        sha256: String?,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        // No 206 from the server (or a middlebox strips Range): parallel
        // segments are off the table, stream the body whole.
        guard let total = try await probeRangeSupport(url) else {
            try await plainStream(url, to: part, onBytes: onBytes)
            return
        }

        let partSize = Int64(
            (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let resumed = validResumeState(at: meta, partSize: partSize, sha256: sha256)
            .flatMap { $0.total == total ? $0 : nil }
        let state: ResumeState
        if let resumed {
            state = resumed
        } else {
            try preallocate(part, size: total)
            state = ResumeState(
                total: total, sha256: sha256,
                segments: Self.layout(
                    total: total, connections: connections,
                    minBytesPerConnection: minBytesPerConnection))
        }

        let ledger = ProgressLedger(state: state, metaURL: meta, onBytes: onBytes)
        await ledger.begin()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in state.segments.indices {
                    group.addTask {
                        try await runSegment(index, url: url, part: part, ledger: ledger)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            // Keep the ledger current so the next attempt resumes from here.
            await ledger.flush()
            throw error
        }

        if let sha256 {
            guard try await Self.sha256Hex(of: part) == sha256.lowercased() else {
                try? FileManager.default.removeItem(at: part)
                try? FileManager.default.removeItem(at: meta)
                throw Failure.checksumMismatch
            }
        }
    }

    /// Asks for the first byte. A 206 with a parseable Content-Range proves
    /// bounded-Range support and reveals the authoritative size; anything
    /// else means single-stream. The body is never consumed — on a 200 it
    /// would be the entire file — so the session is torn down immediately.
    private func probeRangeSupport(_ url: URL) async throws -> Int64? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .isolatedTransfer)
        defer { session.invalidateAndCancel() }
        let (response, _) = try await HTTPBodyStream.open(request, in: session)
        guard response.statusCode == 206,
              let header = response.value(forHTTPHeaderField: "Content-Range"),
              let range = Self.parseContentRange(header)
        else { return nil }
        return range.total
    }

    private func runSegment(
        _ index: Int, url: URL, part: URL, ledger: ProgressLedger
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await fetchSegment(index, url: url, part: part, ledger: ledger)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt < 3 else { throw error }
                // 2s, 4s — long enough for a flaky connection to recover.
                try await Task.sleep(for: .seconds(Double(1 << attempt)))
            }
        }
    }

    private func fetchSegment(
        _ index: Int, url: URL, part: URL, ledger: ProgressLedger
    ) async throws {
        let segment = await ledger.segment(index)
        guard segment.written < segment.length else { return }
        let from = segment.start + segment.written
        let end = segment.start + segment.length - 1

        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(end)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .isolatedTransfer)
        defer { session.invalidateAndCancel() }

        let (response, body) = try await HTTPBodyStream.open(request, in: session)
        guard response.statusCode == 206 else {
            throw Failure.badStatus(response.statusCode)
        }
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              let range = Self.parseContentRange(header),
              range.start == from, range.end == end
        else {
            throw Failure.mismatchedRange(
                "asked \(from)-\(end), got \(response.value(forHTTPHeaderField: "Content-Range") ?? "nothing")")
        }

        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(from))

        var done = segment.written
        var pending = Data(capacity: 1 << 20)
        for try await chunk in body {
            pending.append(chunk)
            if pending.count >= 1 << 20 {
                // Never write past the segment — excess would clobber a
                // neighbor before any validation could catch it.
                guard done + Int64(pending.count) <= segment.length else {
                    throw Failure.mismatchedRange("server sent more than \(segment.length) bytes")
                }
                try handle.write(contentsOf: pending)
                done += Int64(pending.count)
                await ledger.record(index, delta: Int64(pending.count))
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            guard done + Int64(pending.count) <= segment.length else {
                throw Failure.mismatchedRange("server sent more than \(segment.length) bytes")
            }
            try handle.write(contentsOf: pending)
            done += Int64(pending.count)
            await ledger.record(index, delta: Int64(pending.count))
        }
        try Task.checkCancellation()
        guard done == segment.length else { throw Failure.truncated }
    }

    // MARK: Plain path

    /// One unranged GET streamed into `part`. Only small files and
    /// Range-less servers land here, so there is no cross-attempt resume —
    /// a retry rewrites the file from the start.
    private func plainStream(
        _ url: URL, to part: URL, onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await plainStreamOnce(url, to: part, onBytes: onBytes)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt < 3 else { throw error }
                try await Task.sleep(for: .seconds(Double(1 << attempt)))
            }
        }
    }

    private func plainStreamOnce(
        _ url: URL, to part: URL, onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .isolatedTransfer)
        defer { session.invalidateAndCancel() }

        let (response, body) = try await HTTPBodyStream.open(request, in: session)
        guard (200...299).contains(response.statusCode) else {
            throw Failure.badStatus(response.statusCode)
        }

        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }

        var written: Int64 = 0
        var pending = Data(capacity: 1 << 20)
        for try await chunk in body {
            pending.append(chunk)
            if pending.count >= 1 << 20 {
                try handle.write(contentsOf: pending)
                written += Int64(pending.count)
                onBytes(written)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            try handle.write(contentsOf: pending)
            written += Int64(pending.count)
            onBytes(written)
        }
        try Task.checkCancellation()
    }

    // MARK: Layout & validation (pure, tested)

    /// Split `total` bytes into contiguous segments: as many as
    /// `connections` allows while each keeps at least `minBytesPerConnection`.
    static func layout(
        total: Int64, connections: Int, minBytesPerConnection: Int64
    ) -> [Segment] {
        guard total > 0 else { return [] }
        let count = max(1, min(Int64(connections), total / max(1, minBytesPerConnection)))
        let base = total / count
        return (0..<count).map { index in
            let start = index * base
            let length = index == count - 1 ? total - start : base
            return Segment(start: start, length: length, written: 0)
        }
    }

    /// "bytes 1000-1999/1722271785" → (1000, 1999, 1722271785). Wildcard
    /// forms ("bytes */N") fail — they signal a server we can't segment on.
    static func parseContentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64)? {
        let parts = header.split(separator: " ")
        guard parts.count == 2, parts[0] == "bytes" else { return nil }
        let numbers = parts[1].split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard numbers.count == 3,
              let start = Int64(numbers[0]),
              let end = Int64(numbers[1]),
              let total = Int64(numbers[2]),
              start >= 0, end >= start, total > end
        else { return nil }
        return (start, end, total)
    }

    /// A ledger is only trustworthy if it matches the preallocated part file
    /// and the content identity (sha) the caller expects, and its segments
    /// tile the file exactly.
    func validResumeState(at meta: URL, partSize: Int64, sha256: String?) -> ResumeState? {
        guard let data = try? Data(contentsOf: meta),
              let state = try? JSONDecoder().decode(ResumeState.self, from: data),
              state.sha256 == sha256,
              state.total > 0, partSize == state.total
        else { return nil }
        var cursor: Int64 = 0
        for segment in state.segments {
            guard segment.start == cursor, segment.length > 0,
                  (0...segment.length).contains(segment.written)
            else { return nil }
            cursor += segment.length
        }
        return cursor == state.total ? state : nil
    }

    /// Sparse-preallocate (instant on APFS) so segment writers can seek
    /// anywhere, and so a valid part file always has its final size.
    private func preallocate(_ part: URL, size: Int64) throws {
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    /// Streamed file hash, yielding between chunks so a multi-GB file
    /// doesn't monopolize a cooperative-pool thread.
    static func sha256Hex(of file: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            try Task.checkCancellation()
            await Task.yield()
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Serializes progress across concurrent segment writers, persists the
/// resume ledger every few MB, and feeds the caller's byte counter.
private actor ProgressLedger {
    private var state: SegmentedDownloader.ResumeState
    private let metaURL: URL
    private let onBytes: @Sendable (Int64) -> Void
    private var totalWritten: Int64
    private var unflushed: Int64 = 0
    private let flushStride: Int64 = 8 << 20

    init(
        state: SegmentedDownloader.ResumeState,
        metaURL: URL,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) {
        self.state = state
        self.metaURL = metaURL
        self.onBytes = onBytes
        totalWritten = state.segments.reduce(0) { $0 + $1.written }
    }

    func segment(_ index: Int) -> SegmentedDownloader.Segment {
        state.segments[index]
    }

    /// Persist immediately so even a crash during the first megabytes
    /// leaves a resumable checkpoint, and surface the resumed position.
    func begin() {
        persist()
        onBytes(totalWritten)
    }

    /// Ledger updates happen after the bytes are on disk, so the sidecar
    /// can undercount but never overcount — resumes re-fetch at most the
    /// unflushed tail and overwrite it with identical bytes.
    func record(_ index: Int, delta: Int64) {
        state.segments[index].written += delta
        totalWritten += delta
        unflushed += delta
        if unflushed >= flushStride {
            persist()
            unflushed = 0
        }
        onBytes(totalWritten)
    }

    func flush() {
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }
}

/// Bridges a URLSession data task into (response headers, stream of body
/// chunks). URLSession.AsyncBytes hands out ONE byte per `next()` —
/// harmless for JSON, ruinous for gigabytes, where the async machinery
/// pegs a core and caps throughput. The delegate path delivers whole
/// network reads. Buffering is unbounded, which is safe here because the
/// consumer writes to local flash, far faster than any network source.
private enum HTTPBodyStream {
    static func open(
        _ request: URLRequest, in session: URLSession
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let task = session.dataTask(with: request)
        let bridge = Bridge()
        task.delegate = bridge
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bridge.head = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// All mutable state is confined to the session's serial delegate queue;
    /// `head` is set once before resume(), which orders it ahead of any
    /// callback. Hence @unchecked Sendable.
    private final class Bridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        var head: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>), Error>?
        private var body: AsyncThrowingStream<Data, Error>.Continuation?

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse, let head else {
                completionHandler(.cancel)
                return
            }
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            // A dropped/cancelled consumer must kill the transfer, or a
            // probe that ignores the body would download the whole file.
            continuation.onTermination = { [weak dataTask] reason in
                if case .cancelled = reason { dataTask?.cancel() }
            }
            body = continuation
            self.head = nil
            head.resume(returning: (http, stream))
            completionHandler(.allow)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
        ) {
            body?.yield(data)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) {
            if let head {
                self.head = nil
                head.resume(throwing: error ?? URLError(.badServerResponse))
            }
            if let error {
                body?.finish(throwing: error)
            } else {
                body?.finish()
            }
            body = nil
        }
    }
}

private extension URLSessionConfiguration {
    /// Ephemeral and cache-less: gigabyte responses must never be offered
    /// to URLCache, and separate sessions keep segments on separate TCP
    /// connections (see SegmentedDownloader's type comment). The 30s idle
    /// timeout turns a stalled connection into a fast retry-and-resume.
    static var isolatedTransfer: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        return config
    }
}
