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

        if !useLatest {
            if let cached = try? await HubClient(host: endpoint).downloadSnapshot(
                of: repo,
                kind: .model,
                revision: revision,
                matching: patterns,
                localFilesOnly: true
            ) {
                return cached
            }
            if isValidSnapshot(destination) {
                return destination
            }
        }

        let files = try await listFiles(id: id, revision: revision)
            .filter { matches($0.path, patterns: patterns) }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw HuggingFaceBackgroundError.modelNotFound(id)
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let progress = Progress(totalUnitCount: files.reduce(0) { $0 + $1.size })
        progressHandler(progress)

        var completedBytes: Int64 = 0
        for file in files {
            guard isSafeRelativePath(file.path) else {
                throw HuggingFaceBackgroundError.downloadFailed(file.path)
            }

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

        try writeManifest(files, to: destination)
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

    // MARK: Hugging Face API

    struct FileEntry: Sendable {
        var path: String
        var size: Int64
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

        do {
            return try JSONDecoder().decode([TreeEntry].self, from: data)
                .compactMap { entry in
                    guard entry.type != "directory" else { return nil }
                    return FileEntry(path: entry.path, size: entry.size ?? 0)
                }
        } catch {
            throw HuggingFaceBackgroundError.downloadFailed(error.localizedDescription)
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

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}

enum HuggingFaceBackgroundError: LocalizedError {
    case invalidID(String)
    case modelNotFound(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidID(let id):
            "Invalid Hugging Face model id: \(id)"
        case .modelNotFound(let id):
            "Model \"\(id)\" was not found on Hugging Face."
        case .downloadFailed(let detail):
            "Download failed: \(detail)"
        }
    }
}
