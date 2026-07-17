import CryptoKit
import Foundation
import Observation
import os

/// The download-task shell every model store shares: downloading/progress/
/// lastError state plus the cancel-able task around
/// `ModelFileDownloader.downloadAll`. The manifest loop was extracted long
/// ago; this absorbs the surrounding lifecycle that the SenseVoice and
/// Dolphin stores had each copied verbatim — a store is now its manifest,
/// a directory, and one of these.
@MainActor
@Observable
final class ModelStoreDownloads {
    private let files: [ModelRemoteFile]
    private let directory: URL
    private let logger: Logger

    private(set) var downloading = false
    /// 0…1 across all files, weighted by expected size.
    private(set) var progress: Double = 0
    private(set) var lastError: String?
    private var downloadTask: Task<Void, Never>?

    init(files: [ModelRemoteFile], directory: URL, logCategory: String) {
        self.files = files
        self.directory = directory
        self.logger = Logger(subsystem: "com.kunzhipeng.loqi", category: logCategory)
    }

    func download(from source: ASRModelSource) async {
        guard !downloading else { return }
        downloading = true
        lastError = nil
        progress = 0
        // Run in an owned task so Stop can cancel it; completed-file
        // checkpoints stay on disk and a later download resumes.
        let task = Task { await performDownload(from: source) }
        downloadTask = task
        await task.value
        downloadTask = nil
        downloading = false
    }

    /// User-initiated stop; not an error. Partial files remain for resume.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func performDownload(from source: ASRModelSource) async {
        do {
            // Shared manifest loop: skip-completed resume, per-file
            // verify-or-delete, size-weighted progress.
            try await ModelFileDownloader.downloadAll(
                files, to: directory, from: source
            ) { [weak self] blended in
                Task { @MainActor in self?.progress = blended }
            }
            progress = 1
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            logger.error("download failed: \(error)")
            lastError = String(
                localized: "Download failed — check your connection and try again.")
        }
    }
}

enum ModelFileDownloader {
    enum Mode: Equatable {
        case backgroundURLSession
        case foregroundSegmented
    }

    private static let backgroundThresholdBytes: Int64 = 8 << 20

    static func mode(forExpectedBytes expectedBytes: Int64) -> Mode {
        #if os(iOS)
        expectedBytes > backgroundThresholdBytes ? .backgroundURLSession : .foregroundSegmented
        #else
        .foregroundSegmented
        #endif
    }

    static func download(
        url: URL,
        to destination: URL,
        expectedBytes: Int64,
        sha256: String? = nil,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        if url.isFileURL {
            try await downloadLocalFile(
                url: url,
                to: destination,
                expectedBytes: expectedBytes,
                sha256: sha256,
                onBytes: onBytes)
            return
        }

        switch mode(forExpectedBytes: expectedBytes) {
        case .backgroundURLSession:
            #if os(iOS)
            try await BackgroundModelDownloader.shared.download(
                url: url,
                to: destination,
                expectedBytes: expectedBytes,
                sha256: sha256,
                onBytes: onBytes)
            #else
            try await SegmentedDownloader().download(
                url: url,
                to: destination,
                expectedBytes: expectedBytes,
                sha256: sha256,
                onBytes: onBytes)
            #endif
        case .foregroundSegmented:
            try await SegmentedDownloader().download(
                url: url,
                to: destination,
                expectedBytes: expectedBytes,
                sha256: sha256,
                onBytes: onBytes)
        }
    }

    private static func downloadLocalFile(
        url: URL,
        to destination: URL,
        expectedBytes: Int64,
        sha256: String?,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        if url.standardizedFileURL == destination.standardizedFileURL {
            try await validateDownloadedFile(destination, expectedBytes: expectedBytes, sha256: sha256)
            onBytes(fileSize(of: destination))
            return
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let part = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)

        do {
            try FileManager.default.copyItem(at: url, to: part)
            try await validateDownloadedFile(part, expectedBytes: expectedBytes, sha256: sha256)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.replaceItemAt(destination, withItemAt: part)
            } else {
                try FileManager.default.moveItem(at: part, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }

        onBytes(fileSize(of: destination))
    }

    fileprivate static func validateDownloadedFile(
        _ file: URL,
        expectedBytes: Int64,
        sha256: String?
    ) async throws {
        if expectedBytes > 0, fileSize(of: file) != expectedBytes {
            throw URLError(.badServerResponse)
        }

        if let sha256 {
            let actual = try await SegmentedDownloader.sha256Hex(of: file)
            guard actual == sha256.lowercased() else {
                throw SegmentedDownloader.Failure.checksumMismatch
            }
        }
    }

    private static func fileSize(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

#if os(iOS)
final class BackgroundModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundModelDownloader()
    static let identifier = "com.kunzhipeng.loqi.model-downloads"

    private struct PendingDownload: Codable {
        let id: String
        let destinationPath: String
        let expectedBytes: Int64
        let sha256: String?
    }

    private final class LiveDownload {
        let listenerID: String
        let task: URLSessionDownloadTask
        let continuation: CheckedContinuation<Void, Error>
        let onBytes: @Sendable (Int64) -> Void

        init(
            listenerID: String,
            task: URLSessionDownloadTask,
            continuation: CheckedContinuation<Void, Error>,
            onBytes: @escaping @Sendable (Int64) -> Void
        ) {
            self.listenerID = listenerID
            self.task = task
            self.continuation = continuation
            self.onBytes = onBytes
        }
    }

    private struct ExistingDownloadTask {
        let id: String
        let task: URLSessionDownloadTask
    }

    private static let defaultsKey = "backgroundModelDownloads.pending"

    private let lock = NSLock()
    private var pending: [String: PendingDownload] = BackgroundModelDownloader.loadPending()
    private var live: [String: [LiveDownload]] = [:]
    private var finalizing: Set<String> = []
    private var installing: Set<String> = []
    private var cancelled: Set<String> = []
    private var finishEventsReceived = false
    private var completionHandler: (@Sendable () -> Void)?
    private var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    static func transferID(url: URL, destination: URL) -> String {
        let input = "\(url.absoluteString)\n\(destination.standardizedFileURL.path)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func download(
        url: URL,
        to destination: URL,
        expectedBytes: Int64,
        sha256: String? = nil,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let destination = destination.standardizedFileURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let stableID = Self.transferID(url: url, destination: destination)
        let listenerID = UUID().uuidString
        let existingTask = await downloadTask(
            matching: stableID,
            url: url,
            destination: destination)
        let id = existingTask?.id ?? stableID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                let task: URLSessionDownloadTask
                let shouldResume: Bool
                if let existingTask {
                    task = existingTask.task
                    shouldResume = false
                } else if let activeTask = self.live[id]?.first?.task {
                    task = activeTask
                    shouldResume = false
                } else if let resumeData = Self.takeResumeData(for: id) {
                    task = session.downloadTask(withResumeData: resumeData)
                    task.taskDescription = id
                    shouldResume = true
                } else {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    task = session.downloadTask(with: request)
                    task.taskDescription = id
                    shouldResume = true
                }
                let pending = PendingDownload(
                    id: id,
                    destinationPath: destination.path,
                    expectedBytes: expectedBytes,
                    sha256: sha256)
                let live = LiveDownload(
                    listenerID: listenerID,
                    task: task,
                    continuation: continuation,
                    onBytes: onBytes)

                self.pending[id] = self.pending[id] ?? pending
                self.live[id, default: []].append(live)
                self.installing.remove(id)
                self.cancelled.remove(id)
                persistPendingLocked()
                lock.unlock()

                if Task.isCancelled {
                    self.cancel(id, listenerID: listenerID)
                } else if shouldResume {
                    task.resume()
                } else if task.countOfBytesReceived > 0 {
                    onBytes(task.countOfBytesReceived)
                }
            }
        } onCancel: {
            self.cancel(id, listenerID: listenerID)
        }
    }

    func setCompletionHandler(_ handler: @escaping @Sendable () -> Void, for identifier: String) {
        guard identifier == Self.identifier else {
            handler()
            return
        }
        lock.lock()
        completionHandler = handler
        let readyHandler = drainCompletionHandlerLocked()
        lock.unlock()
        _ = session
        callCompletionHandler(readyHandler)
    }

    private func cancel(_ id: String, listenerID: String) {
        lock.lock()
        guard !installing.contains(id) else {
            lock.unlock()
            return
        }
        var liveDownloads = live[id] ?? []
        guard let index = liveDownloads.firstIndex(where: { $0.listenerID == listenerID }) else {
            lock.unlock()
            return
        }
        let cancelledDownload = liveDownloads.remove(at: index)
        if liveDownloads.isEmpty {
            live[id] = nil
            cancelled.insert(id)
            pending[id] = nil
            persistPendingLocked()
        } else {
            live[id] = liveDownloads
        }
        let shouldCancelTask = liveDownloads.isEmpty
        lock.unlock()

        if shouldCancelTask {
            cancelledDownload.task.cancel(byProducingResumeData: { resumeData in
                if let resumeData, !resumeData.isEmpty {
                    Self.writeResumeData(resumeData, for: id)
                }
                cancelledDownload.continuation.resume(throwing: URLError(.cancelled))
            })
        } else {
            cancelledDownload.continuation.resume(throwing: URLError(.cancelled))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        lock.lock()
        let callbacks = live[id]?.map(\.onBytes) ?? []
        lock.unlock()
        callbacks.forEach { $0(totalBytesWritten) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription,
              let pending = pendingDownload(id)
        else { return }

        beginFinalization(id)

        let destination = URL(fileURLWithPath: pending.destinationPath)
        let part = destination.appendingPathExtension("\(id).part")

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
        } catch {
            complete(id, result: .failure(error))
            finishFinalization(id)
            return
        }

        Task {
            do {
                if self.isCancelled(id) {
                    try? FileManager.default.removeItem(at: part)
                    throw URLError(.cancelled)
                }

                try await ModelFileDownloader.validateDownloadedFile(
                    part,
                    expectedBytes: pending.expectedBytes,
                    sha256: pending.sha256)

                if self.isCancelled(id) {
                    try? FileManager.default.removeItem(at: part)
                    throw URLError(.cancelled)
                }

                guard self.beginInstallIfNotCancelled(id) else {
                    try? FileManager.default.removeItem(at: part)
                    throw URLError(.cancelled)
                }

                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.replaceItemAt(destination, withItemAt: part)
                } else {
                    try FileManager.default.moveItem(at: part, to: destination)
                }
                self.complete(id, result: .success(()))
            } catch {
                try? FileManager.default.removeItem(at: part)
                self.complete(id, result: .failure(error))
            }
            self.finishFinalization(id)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let id = task.taskDescription else { return }
        let resumeData = Self.resumeData(from: error)
        if let resumeData {
            Self.writeResumeData(resumeData, for: id)
        }
        complete(id, result: .failure(error), preserveResumeData: resumeData != nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        finishEventsReceived = true
        let handler = drainCompletionHandlerLocked()
        lock.unlock()
        callCompletionHandler(handler)
    }

    private func pendingDownload(_ id: String) -> PendingDownload? {
        lock.lock()
        let value = pending[id]
        lock.unlock()
        return value
    }

    private func beginFinalization(_ id: String) {
        lock.lock()
        finalizing.insert(id)
        lock.unlock()
    }

    private func finishFinalization(_ id: String) {
        lock.lock()
        finalizing.remove(id)
        let handler = drainCompletionHandlerLocked()
        lock.unlock()
        callCompletionHandler(handler)
    }

    private func beginInstallIfNotCancelled(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled.contains(id) else { return false }
        installing.insert(id)
        return true
    }

    private func isCancelled(_ id: String) -> Bool {
        lock.lock()
        let value = cancelled.contains(id)
        lock.unlock()
        return value
    }

    static func legacyTransferID(
        url: URL,
        destination: URL,
        pendingDestinations: [String: String],
        taskURLs: [(id: String, url: URL?)]
    ) -> String? {
        let destinationPath = destination.standardizedFileURL.path
        return taskURLs.first { task in
            guard let taskURL = task.url,
                  taskURL.absoluteString == url.absoluteString,
                  let pendingDestination = pendingDestinations[task.id]
            else { return false }

            return URL(fileURLWithPath: pendingDestination).standardizedFileURL.path == destinationPath
        }?.id
    }

    private func downloadTask(
        matching id: String,
        url: URL,
        destination: URL
    ) async -> ExistingDownloadTask? {
        let pendingDestinations = pendingDestinationsSnapshot()
        return await withCheckedContinuation { (continuation: CheckedContinuation<ExistingDownloadTask?, Never>) in
            session.getAllTasks { tasks in
                let downloadTasks = tasks.compactMap { $0 as? URLSessionDownloadTask }
                if let exactTask = downloadTasks.first(where: { $0.taskDescription == id }) {
                    continuation.resume(returning: ExistingDownloadTask(id: id, task: exactTask))
                    return
                }

                let taskURLs = downloadTasks.compactMap { task -> (id: String, url: URL?)? in
                    guard let taskID = task.taskDescription else { return nil }
                    return (taskID, task.originalRequest?.url ?? task.currentRequest?.url)
                }
                guard let legacyID = Self.legacyTransferID(
                    url: url,
                    destination: destination,
                    pendingDestinations: pendingDestinations,
                    taskURLs: taskURLs),
                    let legacyTask = downloadTasks.first(where: { $0.taskDescription == legacyID })
                else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: ExistingDownloadTask(id: legacyID, task: legacyTask))
            }
        }
    }

    private func pendingDestinationsSnapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return pending.mapValues(\.destinationPath)
    }

    private func complete(
        _ id: String,
        result: Result<Void, Error>,
        preserveResumeData: Bool = false
    ) {
        lock.lock()
        let liveDownloads = live.removeValue(forKey: id) ?? []
        let wasCancelled = cancelled.contains(id)
        pending[id] = nil
        installing.remove(id)
        cancelled.remove(id)
        if !wasCancelled, !preserveResumeData {
            Self.removeResumeData(for: id)
        }
        persistPendingLocked()
        lock.unlock()

        switch result {
        case .success:
            liveDownloads.forEach { $0.continuation.resume() }
        case .failure(let error):
            liveDownloads.forEach { $0.continuation.resume(throwing: error) }
        }
    }

    private func drainCompletionHandlerLocked() -> (@Sendable () -> Void)? {
        guard finishEventsReceived, finalizing.isEmpty, let handler = completionHandler else {
            return nil
        }
        completionHandler = nil
        finishEventsReceived = false
        return handler
    }

    private static func loadPending() -> [String: PendingDownload] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let pending = try? JSONDecoder().decode([String: PendingDownload].self, from: data)
        else { return [:] }
        return pending
    }

    private static var resumeDataDirectory: URL {
        URL.applicationSupportDirectory.appending(
            path: "BackgroundModelDownloads", directoryHint: .isDirectory)
    }

    private static func resumeDataURL(for id: String) -> URL {
        resumeDataDirectory.appending(path: id).appendingPathExtension("resume")
    }

    private static func writeResumeData(_ data: Data, for id: String) {
        try? FileManager.default.createDirectory(
            at: resumeDataDirectory, withIntermediateDirectories: true)
        try? data.write(to: resumeDataURL(for: id), options: .atomic)
    }

    private static func takeResumeData(for id: String) -> Data? {
        let url = resumeDataURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }

    private static func resumeData(from error: Error) -> Data? {
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        return data?.isEmpty == false ? data : nil
    }

    private static func removeResumeData(for id: String) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: id))
    }

    private func persistPendingLocked() {
        let data = try? JSONEncoder().encode(pending)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func callCompletionHandler(_ handler: (@Sendable () -> Void)?) {
        guard let handler else { return }
        DispatchQueue.main.async {
            handler()
        }
    }
}
#endif

// MARK: - Shared model-file manifests

/// One remote model file with a per-source path — the manifest shape shared
/// by the SenseVoice, Dolphin, and diarizer stores. The HF and ModelScope
/// repos hold the same bytes but differ in owner/revision, so each source
/// carries its own full path.
struct ModelRemoteFile: Sendable {
    /// Path relative to the store's directory — doubles as the local layout
    /// (subdirectories like `tokenizer/…` are created as needed).
    let name: String
    let hfPath: String
    let modelScopePath: String
    /// Sanity floor — a finished file smaller than this is corrupt.
    let minBytes: Int64
    /// Real download size, for progress weighting and size readouts.
    let expectedBytes: Int64

    func path(for source: ASRModelSource) -> String {
        switch source {
        case .huggingFace: hfPath
        case .modelScope: modelScopePath
        }
    }
}

extension ModelFileDownloader {
    static func installedSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// All manifest files present and plausibly sized under `directory`.
    static func allInstalled(_ files: [ModelRemoteFile], in directory: URL) -> Bool {
        files.allSatisfy {
            installedSize(of: directory.appending(path: $0.name)) >= $0.minBytes
        }
    }

    /// Sequential, size-weighted download of a whole manifest: completed
    /// files are skipped (so this doubles as resume), each finished file is
    /// verified against its `minBytes` floor (corrupt → delete + throw),
    /// and `onProgress` reports the blended 0…1 across all files. Per-file
    /// retries, .part checkpointing, and cross-launch resume live in
    /// `download(url:to:…)`.
    static func downloadAll(
        _ files: [ModelRemoteFile],
        to directory: URL,
        from source: ASRModelSource,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let totalWeight = max(files.reduce(0) { $0 + $1.expectedBytes }, 1)
        var doneWeight: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let final = directory.appending(path: file.name)
            if installedSize(of: final) >= file.minBytes {
                doneWeight += file.expectedBytes
                onProgress(Double(doneWeight) / Double(totalWeight))
                continue
            }
            try FileManager.default.createDirectory(
                at: final.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let base = doneWeight
            let url = URL(string: "https://\(source.host)/\(file.path(for: source))")!
            try await download(
                url: url, to: final, expectedBytes: file.expectedBytes
            ) { bytes in
                let fraction = min(1, Double(bytes) / Double(file.expectedBytes))
                onProgress((Double(base) + fraction * Double(file.expectedBytes))
                    / Double(totalWeight))
            }
            guard installedSize(of: final) >= file.minBytes else {
                try? FileManager.default.removeItem(at: final)
                throw URLError(.cannotParseResponse)
            }
            doneWeight += file.expectedBytes
            onProgress(Double(doneWeight) / Double(totalWeight))
        }
    }
}
