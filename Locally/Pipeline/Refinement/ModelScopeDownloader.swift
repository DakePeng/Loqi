import Foundation
import MLXLMCommon

/// Downloads model snapshots from ModelScope (modelscope.cn), for users who
/// can't reach huggingface.co. Conforms to mlx-swift-lm's provider-agnostic
/// `Downloader` protocol; repo ids ("mlx-community/Qwen3.5-2B-OptiQ-4bit")
/// are the same as on Hugging Face for mirrored models.
///
/// API shape (public models, no auth):
///   list:     GET /api/v1/models/{id}/repo/files?Revision={rev}&Recursive=true
///   download: GET /api/v1/models/{id}/repo?Revision={rev}&FilePath={path}
struct ModelScopeDownloader: Downloader {
    var endpoint = URL(string: "https://modelscope.cn")!

    /// Snapshots live in Application Support (excluded from iCloud backup,
    /// not user-visible, survives app updates).
    static var cacheRoot: URL {
        URL.applicationSupportDirectory.appending(path: "ModelScope", directoryHint: .isDirectory)
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let revision = revision.flatMap { $0 == "main" ? nil : $0 } ?? "master"
        let destination = Self.cacheRoot.appending(path: id, directoryHint: .isDirectory)

        if !useLatest, isValidSnapshot(destination) {
            return destination
        }

        let files = try await listFiles(id: id, revision: revision)
            .filter { file in matches(file.path, patterns: patterns) }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw ModelScopeError.modelNotFound(id)
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let progress = Progress(totalUnitCount: files.reduce(0) { $0 + $1.size })
        progressHandler(progress)

        var completedBytes: Int64 = 0
        for file in files {
            let target = destination.appending(path: file.path)
            if let existing = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(existing) == file.size, !useLatest {
                completedBytes += file.size
                progress.completedUnitCount = completedBytes
                progressHandler(progress)
                continue
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            var components = URLComponents(
                url: endpoint.appending(path: "api/v1/models/\(id)/repo"),
                resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "Revision", value: revision),
                URLQueryItem(name: "FilePath", value: file.path),
            ]
            let base = completedBytes
            try await fetchWithRetry(
                components.url!, to: target, expectedSize: file.size
            ) { fileBytes in
                progress.completedUnitCount = base + fileBytes
                progressHandler(progress)
            }
            completedBytes += file.size
            progress.completedUnitCount = completedBytes
            progressHandler(progress)
        }

        removeStalePartials(in: destination)
        try writeManifest(files, to: destination)
        return destination
    }

    // MARK: Snapshot validation

    /// File sizes recorded at download time. A cache hit must match them —
    /// this catches truncated/corrupted files that earlier versions could
    /// leave behind, which otherwise cause endless re-download loops.
    private func manifestURL(_ directory: URL) -> URL {
        directory.appending(path: ".manifest.json")
    }

    func writeManifest(_ files: [FileEntry], to directory: URL) throws {
        let sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.size) })
        let data = try JSONEncoder().encode(sizes)
        try data.write(to: manifestURL(directory))
    }

    func isValidSnapshot(_ directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: manifestURL(directory)),
              let sizes = try? JSONDecoder().decode([String: Int64].self, from: data)
        else { return false }
        for (path, size) in sizes {
            let file = directory.appending(path: path)
            guard let onDisk = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == 0 || Int64(onDisk) == size
            else { return false }
        }
        return !sizes.isEmpty
    }

    // MARK: ModelScope API

    struct FileEntry: Sendable {
        var path: String
        var size: Int64
    }

    private func listFiles(id: String, revision: String) async throws -> [FileEntry] {
        var components = URLComponents(
            url: endpoint.appending(path: "api/v1/models/\(id)/repo/files"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "Revision", value: revision),
            URLQueryItem(name: "Recursive", value: "true"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelScopeError.modelNotFound(id)
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            (root["Code"] as? Int) == 200,
            let payload = root["Data"] as? [String: Any],
            let rawFiles = payload["Files"] as? [[String: Any]]
        else {
            throw ModelScopeError.unexpectedResponse
        }

        return rawFiles.compactMap { raw in
            guard (raw["Type"] as? String) != "tree",
                  let path = raw["Path"] as? String else { return nil }
            let size = (raw["Size"] as? NSNumber)?.int64Value ?? 0
            return FileEntry(path: path, size: size)
        }
    }

    /// Download one file with retry and checkpointing. Partial data lives in
    /// a `.part` file next to the target — it survives both retries and app
    /// restarts, so an interrupted 1GB download resumes instead of starting
    /// over. `onBytes` reports total bytes on disk for this file.
    private func fetchWithRetry(
        _ url: URL,
        to target: URL,
        expectedSize: Int64,
        maxAttempts: Int = 4,
        onBytes: @Sendable (Int64) -> Void
    ) async throws {
        let part = target.appendingPathExtension("part")
        var attempt = 0
        while true {
            do {
                try await resumeDownload(
                    url, into: part, expectedSize: expectedSize, onBytes: onBytes)
                if expectedSize > 0 {
                    let size = Int64(
                        (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    guard size == expectedSize else {
                        try? FileManager.default.removeItem(at: part)
                        throw ModelScopeError.downloadFailed(
                            "\(url.absoluteString) (size \(size) != \(expectedSize))")
                    }
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: part, to: target)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt < maxAttempts else { throw error }
                // 2s, 4s, 8s — long enough for a flaky connection to recover.
                try await Task.sleep(for: .seconds(Double(1 << attempt)))
            }
        }
    }

    /// Streams `url` into `part`, resuming from its current size via an HTTP
    /// Range request.
    ///
    /// ModelScope's servers honor Range requests but answer with status 200
    /// and the FULL Content-Length even for a partial body, so headers can't
    /// distinguish "remainder" from "started over". Instead the request asks
    /// for a 64KB overlap and compares it against the tail of the partial
    /// file: a match proves the stream continues our data (append); a
    /// mismatch proves a full-body restart (rebuild from scratch).
    private func resumeDownload(
        _ url: URL,
        into part: URL,
        expectedSize: Int64,
        onBytes: @Sendable (Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        var written = Int64((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // Resume needs a trustworthy expected size; oversized partials are junk.
        if written > 0, expectedSize <= 0 || written >= expectedSize {
            if written == expectedSize { return }
            try? fm.removeItem(at: part)
            written = 0
        }

        let overlap = written > 0 ? min(Int64(1 << 16), written) : 0
        var request = URLRequest(url: url)
        if written > 0 {
            request.setValue("bytes=\(written - overlap)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206 else {
            throw ModelScopeError.downloadFailed(url.absoluteString)
        }
        var iterator = bytes.makeAsyncIterator()

        if written > 0 {
            var prefix = Data(capacity: Int(overlap))
            while prefix.count < Int(overlap), let byte = try await iterator.next() {
                prefix.append(byte)
            }
            guard prefix.count == Int(overlap) else {
                throw ModelScopeError.downloadFailed("\(url.absoluteString) (interrupted)")
            }

            if prefix == (try tail(of: part, count: overlap)) {
                // Remainder stream: append directly; an interruption leaves
                // a longer valid partial to resume from next attempt.
                let handle = try FileHandle(forWritingTo: part)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try await pump(&iterator, into: handle) { onBytes(written + $0) }
            } else {
                // Full-body restart: rebuild into a side file, swap when done.
                let segment = part.appendingPathExtension("seg")
                try? fm.removeItem(at: segment)
                fm.createFile(atPath: segment.path, contents: nil)
                let handle = try FileHandle(forWritingTo: segment)
                defer { try? handle.close() }
                try handle.write(contentsOf: prefix)
                try await pump(&iterator, into: handle) { onBytes(overlap + $0) }
                try handle.close()
                try? fm.removeItem(at: part)
                try fm.moveItem(at: segment, to: part)
            }
            return
        }

        // Fresh download, straight into the partial file.
        try? fm.removeItem(at: part)
        fm.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try await pump(&iterator, into: handle) { onBytes($0) }
    }

    /// Drain the byte stream into `handle` with 1MB buffered writes,
    /// reporting cumulative bytes written.
    private func pump(
        _ iterator: inout URLSession.AsyncBytes.AsyncIterator,
        into handle: FileHandle,
        onBytes: (Int64) -> Void
    ) async throws {
        var received: Int64 = 0
        var buffer = Data(capacity: 1 << 20)
        while let byte = try await iterator.next() {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                onBytes(received)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            onBytes(received)
        }
    }

    func tail(of file: URL, count: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try handle.seek(toOffset: UInt64(max(0, size - count)))
        return try handle.read(upToCount: Int(count)) ?? Data()
    }

    /// Reclaim disk from cached snapshots of models the app no longer
    /// offers (e.g. after a default-model change ships).
    static func removeSnapshots(notIn keepIDs: Set<String>) {
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: nil) else { return }
        for org in orgs where org.hasDirectoryPath {
            guard let repos = try? fm.contentsOfDirectory(
                at: org, includingPropertiesForKeys: nil) else { continue }
            for repo in repos where repo.hasDirectoryPath {
                let id = "\(org.lastPathComponent)/\(repo.lastPathComponent)"
                if !keepIDs.contains(id) {
                    try? fm.removeItem(at: repo)
                }
            }
        }
    }

    /// Reclaim disk from orphaned partials once their snapshot completed.
    private func removeStalePartials(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where file.pathExtension == "part" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Helpers

    func matches(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        let name = (path as NSString).lastPathComponent
        return patterns.contains { pattern in
            fnmatch(pattern, path, 0) == 0 || fnmatch(pattern, name, 0) == 0
        }
    }
}

enum ModelScopeError: LocalizedError {
    case modelNotFound(String)
    case unexpectedResponse
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let id):
            "Model \"\(id)\" was not found on ModelScope. Try the Hugging Face source instead."
        case .unexpectedResponse:
            "ModelScope returned an unexpected response."
        case .downloadFailed(let url):
            "Download failed: \(url)"
        }
    }
}
