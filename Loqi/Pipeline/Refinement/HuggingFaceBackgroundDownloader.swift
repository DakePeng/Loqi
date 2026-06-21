import Foundation
import HuggingFace
import MLXLMCommon

/// Downloads Hugging Face model snapshots through Loqi's model transfer
/// primitive, so large iOS files can continue in a background URLSession.
struct HuggingFaceBackgroundDownloader: Downloader {
    var endpoint = URL(string: "https://huggingface.co")!

    static var cacheRoot: URL {
        URL.applicationSupportDirectory.appending(path: "HuggingFace", directoryHint: .isDirectory)
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw HuggingFaceBackgroundError.invalidID(id)
        }
        let revision = revision ?? "main"
        let destination = Self.cacheRoot.appending(path: id, directoryHint: .isDirectory)

        if !useLatest, isValidSnapshot(destination, revision: revision, patterns: patterns) {
            return destination
        }

        let files = try await listFiles(id: id, revision: revision)
            .filter { matches($0.path, patterns: patterns) }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw HuggingFaceBackgroundError.modelNotFound(id)
        }
        guard files.allSatisfy({ isSafeRelativePath($0.path) }) else {
            throw HuggingFaceBackgroundError.downloadFailed("Unsafe path in model tree.")
        }

        if !useLatest {
            if let cached = try? await HubClient(host: endpoint).downloadSnapshot(
                of: repo,
                kind: .model,
                revision: revision,
                matching: patterns,
                localFilesOnly: true
            ), containsFiles(cached, for: files) {
                return cached
            }
            if isValidSnapshot(destination, for: files) {
                return destination
            }
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

            let downloadURL = endpoint.appending(path: "\(id)/resolve/\(revision)/\(file.path)")
            let base = completedBytes
            try await ModelFileDownloader.download(
                url: downloadURL,
                to: target,
                expectedBytes: file.size
            ) { bytes in
                progress.completedUnitCount = base + min(bytes, file.size)
                progressHandler(progress)
            }

            if file.size > 0 {
                let size = Int64(
                    (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard size == file.size else {
                    try? FileManager.default.removeItem(at: target)
                    throw HuggingFaceBackgroundError.downloadFailed(
                        "\(file.path) (size \(size) != \(file.size))")
                }
            }

            completedBytes += file.size
            progress.completedUnitCount = completedBytes
            progressHandler(progress)
        }

        removeStalePartials(in: destination)
        try writeManifest(files, to: destination, revision: revision, patterns: patterns)
        return destination
    }

    // MARK: Snapshot validation

    private func manifestURL(_ directory: URL) -> URL {
        directory.appending(path: ".manifest.json")
    }

    func writeManifest(_ files: [FileEntry], to directory: URL) throws {
        let sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.size) })
        let data = try JSONEncoder().encode(sizes)
        try data.write(to: manifestURL(directory))
    }

    func writeManifest(
        _ files: [FileEntry],
        to directory: URL,
        revision: String,
        patterns: [String]
    ) throws {
        let manifest = SnapshotManifest(revision: revision, patterns: patterns, files: files)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(directory))
    }

    func isValidSnapshot(_ directory: URL) -> Bool {
        guard let files = try? manifestFiles(in: directory) else { return false }
        return isValidSnapshot(directory, for: files)
    }

    func isValidSnapshot(_ directory: URL, for files: [FileEntry]) -> Bool {
        guard let manifestFiles = try? manifestFiles(in: directory) else { return false }
        let sizes = Dictionary(uniqueKeysWithValues: manifestFiles.map { ($0.path, $0.size) })
        guard !files.isEmpty else { return false }
        for fileEntry in files {
            guard sizes[fileEntry.path] == fileEntry.size else { return false }
            let path = fileEntry.path
            let size = fileEntry.size
            let file = directory.appending(path: path)
            guard let onDisk = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == 0 || Int64(onDisk) == size
            else { return false }
        }
        return true
    }

    func isValidSnapshot(_ directory: URL, revision: String, patterns: [String]) -> Bool {
        guard let manifest = try? metadataManifest(in: directory),
              manifest.revision == revision,
              manifest.patterns == patterns,
              manifest.files.contains(where: { $0.path.hasSuffix(".safetensors") })
        else { return false }
        return containsFiles(directory, for: manifest.files)
    }

    private func containsFiles(_ directory: URL, for files: [FileEntry]) -> Bool {
        guard !files.isEmpty else { return false }
        for fileEntry in files {
            let file = directory.appending(path: fileEntry.path)
            guard let onDisk = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileEntry.size == 0 || Int64(onDisk) == fileEntry.size
            else { return false }
        }
        return true
    }

    private func manifestFiles(in directory: URL) throws -> [FileEntry] {
        let data = try Data(contentsOf: manifestURL(directory))
        if let manifest = try? JSONDecoder().decode(SnapshotManifest.self, from: data) {
            return manifest.files
        }
        let sizes = try JSONDecoder().decode([String: Int64].self, from: data)
        return sizes.map { FileEntry(path: $0.key, size: $0.value) }
    }

    private func metadataManifest(in directory: URL) throws -> SnapshotManifest {
        let data = try Data(contentsOf: manifestURL(directory))
        return try JSONDecoder().decode(SnapshotManifest.self, from: data)
    }

    // MARK: Hugging Face API

    struct FileEntry: Codable, Sendable {
        var path: String
        var size: Int64
    }

    private struct SnapshotManifest: Codable {
        var revision: String
        var patterns: [String]
        var files: [FileEntry]
    }

    private struct TreeEntry: Decodable {
        var path: String
        var type: String
        var size: Int64?
    }

    private func listFiles(id: String, revision: String) async throws -> [FileEntry] {
        var components = URLComponents(
            url: endpoint.appending(path: "api/models/\(id)/tree/\(revision)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "recursive", value: "1"),
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HuggingFaceBackgroundError.modelNotFound(id)
        }

        let entries: [TreeEntry]
        do {
            entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        } catch {
            throw HuggingFaceBackgroundError.downloadFailed(error.localizedDescription)
        }

        return try entries.compactMap { entry in
            guard entry.type != "directory" else { return nil }
            guard let size = entry.size else {
                throw HuggingFaceBackgroundError.unexpectedResponse(
                    "\(entry.path) is missing size")
                }
            return FileEntry(path: entry.path, size: size)
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

    func removeStalePartials(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator
        where ["part", "meta"].contains(file.pathExtension) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != ".." }
    }
}

enum HuggingFaceBackgroundError: LocalizedError {
    case invalidID(String)
    case modelNotFound(String)
    case unexpectedResponse(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidID(let id):
            "Invalid Hugging Face model id: \(id)"
        case .modelNotFound(let id):
            "Model \"\(id)\" was not found on Hugging Face."
        case .unexpectedResponse(let detail):
            "Hugging Face returned an unexpected response: \(detail)"
        case .downloadFailed(let detail):
            "Download failed: \(detail)"
        }
    }
}
