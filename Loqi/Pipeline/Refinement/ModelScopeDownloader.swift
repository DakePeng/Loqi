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
///             (302s to the LFS CDN, which honors bounded Range requests —
///             large files go through SegmentedDownloader's parallel
///             connections instead of one throttled stream)
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
            try await ModelFileDownloader.download(
                url: components.url!, to: target,
                expectedBytes: file.size, sha256: file.sha256
            ) { bytes in
                progress.completedUnitCount = base + min(bytes, file.size)
                progressHandler(progress)
            }
            if file.size > 0 {
                let size = Int64(
                    (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard size == file.size else {
                    try? FileManager.default.removeItem(at: target)
                    throw ModelScopeError.downloadFailed(
                        "\(file.path) (size \(size) != \(file.size))")
                }
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
        /// From the list API; verified after segmented downloads.
        var sha256: String? = nil
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
            return FileEntry(path: path, size: size, sha256: raw["Sha256"] as? String)
        }
    }

    /// Force a re-list on the next download when `model` needs vision
    /// files its cached snapshot predates: the manifest otherwise reports
    /// the old snapshot complete forever, so the newly added processor
    /// configs (and the grown weights) would never be fetched. Re-listing
    /// only downloads missing or size-changed files.
    static func invalidateSnapshotIfMissingVisionFiles(model: ModelOption) {
        guard model.supportsVision else { return }
        let directory = cacheRoot.appending(path: model.id, directoryHint: .isDirectory)
        let fm = FileManager.default
        let manifest = directory.appending(path: ".manifest.json")
        guard fm.fileExists(atPath: manifest.path),
              !fm.fileExists(
                atPath: directory.appending(path: "preprocessor_config.json").path)
        else { return }
        try? fm.removeItem(at: manifest)
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

    /// Reclaim disk from orphaned partials and resume ledgers once their
    /// snapshot completed.
    private func removeStalePartials(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator
        where ["part", "meta"].contains(file.pathExtension) {
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
