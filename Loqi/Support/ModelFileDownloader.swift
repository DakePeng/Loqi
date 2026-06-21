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
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            onBytes(Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
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
        let task: URLSessionDownloadTask
        let continuation: CheckedContinuation<Void, Error>
        let onBytes: @Sendable (Int64) -> Void

        init(
            task: URLSessionDownloadTask,
            continuation: CheckedContinuation<Void, Error>,
            onBytes: @escaping @Sendable (Int64) -> Void
        ) {
            self.task = task
            self.continuation = continuation
            self.onBytes = onBytes
        }
    }

    private static let defaultsKey = "backgroundModelDownloads.pending"

    private let lock = NSLock()
    private var pending: [String: PendingDownload] = BackgroundModelDownloader.loadPending()
    private var live: [String: LiveDownload] = [:]
    private var completionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func download(
        url: URL,
        to destination: URL,
        expectedBytes: Int64,
        sha256: String? = nil,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let id = UUID().uuidString
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let task = session.downloadTask(with: request)
                task.taskDescription = id

                let pending = PendingDownload(
                    id: id,
                    destinationPath: destination.path,
                    expectedBytes: expectedBytes,
                    sha256: sha256)
                let live = LiveDownload(
                    task: task,
                    continuation: continuation,
                    onBytes: onBytes)

                lock.lock()
                self.pending[id] = pending
                self.live[id] = live
                persistPendingLocked()
                lock.unlock()

                if Task.isCancelled {
                    self.cancel(id)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    func setCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        guard identifier == Self.identifier else {
            handler()
            return
        }
        lock.lock()
        completionHandler = handler
        lock.unlock()
        _ = session
    }

    private func cancel(_ id: String) {
        lock.lock()
        let liveDownload = live.removeValue(forKey: id)
        pending[id] = nil
        persistPendingLocked()
        lock.unlock()

        liveDownload?.task.cancel()
        liveDownload?.continuation.resume(throwing: URLError(.cancelled))
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
        let callback = live[id]?.onBytes
        lock.unlock()
        callback?(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription,
              let pending = pendingDownload(id)
        else { return }

        let destination = URL(fileURLWithPath: pending.destinationPath)
        let part = destination.appendingPathExtension("part")

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
        } catch {
            complete(id, result: .failure(error))
            return
        }

        Task {
            do {
                if let sha256 = pending.sha256 {
                    let actual = try await SegmentedDownloader.sha256Hex(of: part)
                    guard actual == sha256.lowercased() else {
                        try? FileManager.default.removeItem(at: part)
                        throw SegmentedDownloader.Failure.checksumMismatch
                    }
                }

                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.replaceItemAt(destination, withItemAt: part)
                } else {
                    try FileManager.default.moveItem(at: part, to: destination)
                }
                self.complete(id, result: .success(()))
            } catch {
                self.complete(id, result: .failure(error))
            }
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
        let handler = completionHandler
        completionHandler = nil
        lock.unlock()
        DispatchQueue.main.async {
            handler?()
        }
    }

    private func pendingDownload(_ id: String) -> PendingDownload? {
        lock.lock()
        let value = pending[id]
        lock.unlock()
        return value
    }

    private func complete(_ id: String, result: Result<Void, Error>) {
        lock.lock()
        let liveDownload = live.removeValue(forKey: id)
        pending[id] = nil
        persistPendingLocked()
        lock.unlock()

        guard let liveDownload else { return }
        switch result {
        case .success:
            liveDownload.continuation.resume()
        case .failure(let error):
            liveDownload.continuation.resume(throwing: error)
        }
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
}
#endif
