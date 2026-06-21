import CryptoKit
import Foundation

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

        let id = Self.transferID(url: url, destination: destination)
        let listenerID = UUID().uuidString
        let existingTask = await downloadTask(with: id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let pending = PendingDownload(
                    id: id,
                    destinationPath: destination.path,
                    expectedBytes: expectedBytes,
                    sha256: sha256)

                lock.lock()
                let task: URLSessionDownloadTask
                let shouldResume: Bool
                if let existingTask {
                    task = existingTask
                    shouldResume = false
                } else if let activeTask = self.live[id]?.first?.task {
                    task = activeTask
                    shouldResume = false
                } else {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    task = session.downloadTask(with: request)
                    task.taskDescription = id
                    shouldResume = true
                }
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
            cancelledDownload.task.cancel()
        }
        cancelledDownload.continuation.resume(throwing: URLError(.cancelled))
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
        complete(id, result: .failure(error))
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

    private func downloadTask(with id: String) async -> URLSessionDownloadTask? {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let downloadTask = tasks.compactMap { $0 as? URLSessionDownloadTask }
                    .first { $0.taskDescription == id }
                continuation.resume(returning: downloadTask)
            }
        }
    }

    private func complete(_ id: String, result: Result<Void, Error>) {
        lock.lock()
        let liveDownloads = live.removeValue(forKey: id) ?? []
        pending[id] = nil
        installing.remove(id)
        cancelled.remove(id)
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
