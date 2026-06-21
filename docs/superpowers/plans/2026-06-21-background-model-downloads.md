# Background Model Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Loqi model file downloads continue through iOS backgrounding and locked-screen time, without changing recording, transcription, summary, or ML execution behavior.

**Architecture:** Add one model-file download facade that routes large iOS model files to a native background `URLSession` download helper and keeps small/non-iOS transfers on the existing `SegmentedDownloader`. Reuse existing model stores and progress surfaces. Add a local Hugging Face `Downloader` implementation so MLX model downloads can use the same background-capable transfer path without patching dependencies.

**Tech Stack:** Swift 6, SwiftUI app lifecycle, UIKit background URLSession delegate bridge, `URLSessionConfiguration.background`, existing `SegmentedDownloader`, MLXLMCommon `Downloader`, Swift Testing.

---

## File Structure

- Create `Loqi/Support/ModelFileDownloader.swift`: facade, iOS background URLSession helper, transfer policy.
- Create `Loqi/Pipeline/Refinement/HuggingFaceBackgroundDownloader.swift`: MLX `Downloader` for Hugging Face model snapshots using `ModelFileDownloader`.
- Create `LoqiTests/ModelFileDownloaderTests.swift`: small policy tests.
- Create `LoqiTests/HuggingFaceBackgroundDownloaderTests.swift`: manifest and glob tests for the new Hugging Face snapshot downloader.
- Modify `Loqi/Pipeline/ASR/SenseVoiceModelStore.swift`: replace direct `SegmentedDownloader` call.
- Modify `Loqi/Pipeline/ASR/Qwen3ASRModelStore.swift`: replace direct `SegmentedDownloader` call.
- Modify `Loqi/Pipeline/Refinement/ModelScopeDownloader.swift`: replace direct `SegmentedDownloader` call.
- Modify `Loqi/Pipeline/Refinement/LLMService.swift`: use `HuggingFaceBackgroundDownloader` for Hugging Face downloads and include its cache in downloaded detection.
- Modify `Loqi/LoqiApp.swift`: add UIKit app delegate bridge for background URLSession events.
- Regenerate `Loqi.xcodeproj` with `xcodegen generate` because new Swift files must be included in the committed project.

---

### Task 1: Add Download Policy Test And Facade

**Files:**
- Create: `LoqiTests/ModelFileDownloaderTests.swift`
- Create: `Loqi/Support/ModelFileDownloader.swift`
- Modify: `Loqi.xcodeproj/project.pbxproj` via `xcodegen generate`

- [ ] **Step 1: Write the failing policy test**

Create `LoqiTests/ModelFileDownloaderTests.swift`:

```swift
import Testing
@testable import Loqi

struct ModelFileDownloaderTests {
    @Test func largeModelFilesUseBackgroundTransferOnIOS() {
        #if os(iOS)
        #expect(ModelFileDownloader.mode(forExpectedBytes: 239_233_841) == .backgroundURLSession)
        #else
        #expect(ModelFileDownloader.mode(forExpectedBytes: 239_233_841) == .foregroundSegmented)
        #endif
    }

    @Test func smallModelFilesStayOnForegroundTransfer() {
        #expect(ModelFileDownloader.mode(forExpectedBytes: 320_000) == .foregroundSegmented)
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/ModelFileDownloaderTests -jobs 1
```

Expected: FAIL because `ModelFileDownloader` does not exist.

- [ ] **Step 3: Add the minimal facade and policy**

Create `Loqi/Support/ModelFileDownloader.swift`:

```swift
import Foundation

enum ModelFileDownloader {
    enum Mode: Equatable {
        case backgroundURLSession
        case foregroundSegmented
    }

    private static let backgroundThresholdBytes: Int64 = 8 << 20

    static func mode(forExpectedBytes expectedBytes: Int64) -> Mode {
        #if os(iOS)
        expectedBytes >= backgroundThresholdBytes ? .backgroundURLSession : .foregroundSegmented
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
```

- [ ] **Step 4: Regenerate the project**

Run:

```bash
xcodegen generate
```

Expected: `Loqi.xcodeproj/project.pbxproj` includes `ModelFileDownloader.swift` and `ModelFileDownloaderTests.swift`.

- [ ] **Step 5: Run the focused test and verify it passes**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/ModelFileDownloaderTests -jobs 1
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Loqi/Support/ModelFileDownloader.swift LoqiTests/ModelFileDownloaderTests.swift Loqi.xcodeproj/project.pbxproj
git commit -m "feat: add model download transfer policy"
```

---

### Task 2: Implement The iOS Background Download Helper

**Files:**
- Modify: `Loqi/Support/ModelFileDownloader.swift`
- Test: `LoqiTests/ModelFileDownloaderTests.swift`

- [ ] **Step 1: Add a cancellation-safe no-network test for missing files**

Append this test to `LoqiTests/ModelFileDownloaderTests.swift`:

```swift
    @Test func foregroundModeRemainsAvailableForTinyFiles() async throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appending(path: "tiny.bin")
        let source = dir.appending(path: "source.bin")
        try Data("ok".utf8).write(to: source)

        try await ModelFileDownloader.download(
            url: source,
            to: destination,
            expectedBytes: 2
        ) { _ in }

        #expect((try Data(contentsOf: destination)) == Data("ok".utf8))
    }
```

- [ ] **Step 2: Run the focused tests and verify the tiny file path fails**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/ModelFileDownloaderTests -jobs 1
```

Expected: FAIL on the tiny file test because `SegmentedDownloader` expects HTTP responses, not `file://` URLs. This confirms the test needs a small local fast path in the facade.

- [ ] **Step 3: Add local file fast path and the background helper**

Replace `Loqi/Support/ModelFileDownloader.swift` with:

```swift
import Foundation

enum ModelFileDownloader {
    enum Mode: Equatable {
        case backgroundURLSession
        case foregroundSegmented
    }

    private static let backgroundThresholdBytes: Int64 = 8 << 20

    static func mode(forExpectedBytes expectedBytes: Int64) -> Mode {
        #if os(iOS)
        expectedBytes >= backgroundThresholdBytes ? .backgroundURLSession : .foregroundSegmented
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
    private var pending: [String: PendingDownload] = Self.loadPending()
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
        sha256: String?,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let id = UUID().uuidString
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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

                task.resume()
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
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: part, to: destination)
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
```

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/ModelFileDownloaderTests -jobs 1
```

Expected: PASS.

- [ ] **Step 5: Build once to catch delegate/signature errors**

Run:

```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Loqi/Support/ModelFileDownloader.swift LoqiTests/ModelFileDownloaderTests.swift
git commit -m "feat: add background model file downloader"
```

---

### Task 3: Route Existing Direct Model File Downloads Through The Facade

**Files:**
- Modify: `Loqi/Pipeline/ASR/SenseVoiceModelStore.swift`
- Modify: `Loqi/Pipeline/ASR/Qwen3ASRModelStore.swift`
- Modify: `Loqi/Pipeline/Refinement/ModelScopeDownloader.swift`
- Test: `LoqiTests/ModelFileDownloaderTests.swift`

- [ ] **Step 1: Add a no-direct-use guard test**

Append this test to `LoqiTests/ModelFileDownloaderTests.swift`:

```swift
    @Test func modelStoresNoLongerCallSegmentedDownloaderDirectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            root.appending(path: "Loqi/Pipeline/ASR/SenseVoiceModelStore.swift"),
            root.appending(path: "Loqi/Pipeline/ASR/Qwen3ASRModelStore.swift"),
            root.appending(path: "Loqi/Pipeline/Refinement/ModelScopeDownloader.swift"),
        ]

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("SegmentedDownloader().download("), "\(file.lastPathComponent) still bypasses ModelFileDownloader")
        }
    }
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/ModelFileDownloaderTests/modelStoresNoLongerCallSegmentedDownloaderDirectly -jobs 1
```

Expected: FAIL because the three files still call `SegmentedDownloader().download(`.

- [ ] **Step 3: Replace SenseVoice transfer primitive**

In `Loqi/Pipeline/ASR/SenseVoiceModelStore.swift`, replace:

```swift
        try await SegmentedDownloader().download(
            url: url, to: final, expectedBytes: file.expectedBytes
        ) { bytes in
            let fraction = min(1, Double(bytes) / Double(file.expectedBytes))
            Task { @MainActor in onProgress(fraction) }
        }
```

with:

```swift
        try await ModelFileDownloader.download(
            url: url, to: final, expectedBytes: file.expectedBytes
        ) { bytes in
            let fraction = min(1, Double(bytes) / Double(file.expectedBytes))
            Task { @MainActor in onProgress(fraction) }
        }
```

- [ ] **Step 4: Replace Qwen3-ASR transfer primitive**

In `Loqi/Pipeline/ASR/Qwen3ASRModelStore.swift`, replace:

```swift
        try await SegmentedDownloader().download(
            url: url, to: final, expectedBytes: file.expectedBytes
        ) { bytes in
            let fraction = min(1, Double(bytes) / Double(file.expectedBytes))
            Task { @MainActor in onProgress(fraction) }
        }
```

with:

```swift
        try await ModelFileDownloader.download(
            url: url, to: final, expectedBytes: file.expectedBytes
        ) { bytes in
            let fraction = min(1, Double(bytes) / Double(file.expectedBytes))
            Task { @MainActor in onProgress(fraction) }
        }
```

- [ ] **Step 5: Replace ModelScope transfer primitive**

In `Loqi/Pipeline/Refinement/ModelScopeDownloader.swift`, replace:

```swift
            try await SegmentedDownloader().download(
                url: components.url!, to: target,
                expectedBytes: file.size, sha256: file.sha256
            ) { bytes in
                progress.completedUnitCount = base + min(bytes, file.size)
                progressHandler(progress)
            }
```

with:

```swift
            try await ModelFileDownloader.download(
                url: components.url!, to: target,
                expectedBytes: file.size, sha256: file.sha256
            ) { bytes in
                progress.completedUnitCount = base + min(bytes, file.size)
                progressHandler(progress)
            }
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/ModelFileDownloaderTests -jobs 1
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Loqi/Pipeline/ASR/SenseVoiceModelStore.swift Loqi/Pipeline/ASR/Qwen3ASRModelStore.swift Loqi/Pipeline/Refinement/ModelScopeDownloader.swift LoqiTests/ModelFileDownloaderTests.swift
git commit -m "refactor: route model files through download facade"
```

---

### Task 4: Add Hugging Face Background Snapshot Downloader

**Files:**
- Create: `Loqi/Pipeline/Refinement/HuggingFaceBackgroundDownloader.swift`
- Create: `LoqiTests/HuggingFaceBackgroundDownloaderTests.swift`
- Modify: `Loqi.xcodeproj/project.pbxproj` via `xcodegen generate`

- [ ] **Step 1: Write manifest and matching tests**

Create `LoqiTests/HuggingFaceBackgroundDownloaderTests.swift`:

```swift
import Foundation
import Testing
@testable import Loqi

struct HuggingFaceBackgroundDownloaderTests {
    let downloader = HuggingFaceBackgroundDownloader()

    @Test func matchesPathOrFileName() {
        #expect(downloader.matches("model-00001-of-00002.safetensors", patterns: ["*.safetensors"]))
        #expect(downloader.matches("tokenizer/tokenizer.json", patterns: ["tokenizer/*.json"]))
        #expect(downloader.matches("config.json", patterns: ["*.json"]))
        #expect(!downloader.matches("notes.md", patterns: ["*.json"]))
    }

    @Test func manifestValidationRejectsMissingFile() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try downloader.writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(path: "weights.safetensors", size: 10)],
            to: dir)

        #expect(!downloader.isValidSnapshot(dir))
    }

    @Test func manifestValidationAcceptsMatchingSizes() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(count: 10).write(to: dir.appending(path: "weights.safetensors"))
        try downloader.writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(path: "weights.safetensors", size: 10)],
            to: dir)

        #expect(downloader.isValidSnapshot(dir))
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/HuggingFaceBackgroundDownloaderTests -jobs 1
```

Expected: FAIL because `HuggingFaceBackgroundDownloader` does not exist.

- [ ] **Step 3: Add the downloader**

Create `Loqi/Pipeline/Refinement/HuggingFaceBackgroundDownloader.swift`:

```swift
import Foundation
import HuggingFace
import MLXLMCommon

struct HuggingFaceBackgroundDownloader: Downloader {
    var endpoint = URL(string: "https://huggingface.co")!

    static var cacheRoot: URL {
        URL.applicationSupportDirectory.appending(path: "HuggingFace", directoryHint: .isDirectory)
    }

    struct FileEntry: Sendable {
        var path: String
        var size: Int64
    }

    private struct TreeEntry: Decodable {
        var path: String
        var type: String
        var size: Int64?
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw HuggingFaceBackgroundError.invalidRepositoryID(id)
        }
        let revision = revision ?? "main"

        if !useLatest,
           let cached = try? await HubClient().downloadSnapshot(
            of: repoID,
            revision: revision,
            matching: patterns,
            localFilesOnly: true
           ) {
            return cached
        }

        let destination = Self.cacheRoot.appending(path: id, directoryHint: .isDirectory)
        if !useLatest, isValidSnapshot(destination) {
            return destination
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
            let target = destination.appending(path: file.path)
            if let existing = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(existing) == file.size, !useLatest {
                completedBytes += file.size
                progress.completedUnitCount = completedBytes
                progressHandler(progress)
                continue
            }

            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)

            let base = completedBytes
            try await ModelFileDownloader.download(
                url: resolveURL(id: id, revision: revision, path: file.path),
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

    func writeManifest(_ files: [FileEntry], to directory: URL) throws {
        let sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.size) })
        let data = try JSONEncoder().encode(sizes)
        try data.write(to: manifestURL(directory), options: .atomic)
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

    func matches(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        let name = (path as NSString).lastPathComponent
        return patterns.contains { pattern in
            fnmatch(pattern, path, 0) == 0 || fnmatch(pattern, name, 0) == 0
        }
    }

    private func manifestURL(_ directory: URL) -> URL {
        directory.appending(path: ".manifest.json")
    }

    private func listFiles(id: String, revision: String) async throws -> [FileEntry] {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw HuggingFaceBackgroundError.invalidRepositoryID(id)
        }

        var url = endpoint
            .appending(path: "api")
            .appending(path: "models")
            .appending(path: parts[0])
            .appending(path: parts[1])
            .appending(path: "tree")
            .appending(path: revision)
        url.append(queryItems: [URLQueryItem(name: "recursive", value: "1")])

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HuggingFaceBackgroundError.modelNotFound(id)
        }

        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        return entries.compactMap { entry in
            guard entry.type == "file" else { return nil }
            return FileEntry(path: entry.path, size: entry.size ?? 0)
        }
    }

    private func resolveURL(id: String, revision: String, path: String) -> URL {
        let encodedPath = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "\(endpoint.absoluteString)/\(id)/resolve/\(revision)/\(encodedPath)")!
    }
}

enum HuggingFaceBackgroundError: LocalizedError {
    case invalidRepositoryID(String)
    case modelNotFound(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            "Invalid Hugging Face model id: \(id)"
        case .modelNotFound(let id):
            "Model \"\(id)\" was not found on Hugging Face. Try ModelScope instead."
        case .downloadFailed(let detail):
            "Download failed: \(detail)"
        }
    }
}
```

- [ ] **Step 4: Regenerate the project**

Run:

```bash
xcodegen generate
```

Expected: `Loqi.xcodeproj/project.pbxproj` includes `HuggingFaceBackgroundDownloader.swift` and `HuggingFaceBackgroundDownloaderTests.swift`.

- [ ] **Step 5: Run focused tests**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/HuggingFaceBackgroundDownloaderTests -jobs 1
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Loqi/Pipeline/Refinement/HuggingFaceBackgroundDownloader.swift LoqiTests/HuggingFaceBackgroundDownloaderTests.swift Loqi.xcodeproj/project.pbxproj
git commit -m "feat: add hugging face background downloader"
```

---

### Task 5: Switch LLMService To The New Hugging Face Downloader

**Files:**
- Modify: `Loqi/Pipeline/Refinement/LLMService.swift`
- Test: `LoqiTests/LLMServiceTests.swift`

- [ ] **Step 1: Add a downloaded-detection test for the new cache**

Append this test to `LoqiTests/LLMServiceTests.swift`:

```swift
    @Test func backgroundHuggingFaceSnapshotCountsAsDownloaded() throws {
        let model = ModelCatalog.qwen35_0_8b
        let snapshot = HuggingFaceBackgroundDownloader.cacheRoot.appending(
            path: model.id,
            directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshot) }

        let weight = snapshot.appending(path: "weights.safetensors")
        try Data(count: Int(Double(model.downloadBytes) * 0.81)).write(to: weight)
        try HuggingFaceBackgroundDownloader().writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(
                path: "weights.safetensors",
                size: Int64(Double(model.downloadBytes) * 0.81))],
            to: snapshot)
        if model.supportsVision {
            try Data("{}".utf8).write(to: snapshot.appending(path: "preprocessor_config.json"))
        }

        #expect(LLMService.isDownloaded(model: model))
    }
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/LLMServiceTests/backgroundHuggingFaceSnapshotCountsAsDownloaded -jobs 1
```

Expected: FAIL because `LLMService.isDownloaded` does not check `HuggingFaceBackgroundDownloader.cacheRoot`.

- [ ] **Step 3: Add the new cache to downloaded detection**

In `Loqi/Pipeline/Refinement/LLMService.swift`, inside `isDownloaded(model:)`, after the ModelScope snapshot check and before `return hubSnapshotLooksComplete(model: model)`, insert:

```swift
        let backgroundHFSnapshot = HuggingFaceBackgroundDownloader.cacheRoot.appending(
            path: model.id, directoryHint: .isDirectory)
        if HuggingFaceBackgroundDownloader().isValidSnapshot(backgroundHFSnapshot),
           visionFilesPresent(model: model, in: backgroundHFSnapshot) {
            return true
        }
```

- [ ] **Step 4: Switch the Hugging Face downloader**

In `Loqi/Pipeline/Refinement/LLMService.swift`, replace:

```swift
                case .huggingFace: #hubDownloader()
                case .modelScope: ModelScopeDownloader()
```

with:

```swift
                case .huggingFace: HuggingFaceBackgroundDownloader()
                case .modelScope: ModelScopeDownloader()
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/LLMServiceTests/backgroundHuggingFaceSnapshotCountsAsDownloaded -jobs 1
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Loqi/Pipeline/Refinement/LLMService.swift LoqiTests/LLMServiceTests.swift
git commit -m "feat: use background downloader for hugging face models"
```

---

### Task 6: Add The App Delegate Bridge

**Files:**
- Modify: `Loqi/LoqiApp.swift`
- Test: manual build

- [ ] **Step 1: Add the UIKit bridge**

In `Loqi/LoqiApp.swift`, add this class before `@main`:

```swift
#if os(iOS)
final class LoqiAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundModelDownloader.shared.setCompletionHandler(
            completionHandler,
            for: identifier)
    }
}
#endif
```

Then add this property inside `struct LoqiApp: App`:

```swift
    #if os(iOS)
    @UIApplicationDelegateAdaptor(LoqiAppDelegate.self) private var appDelegate
    #endif
```

- [ ] **Step 2: Build once**

Run:

```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Loqi/LoqiApp.swift
git commit -m "feat: handle background download wakeups"
```

---

### Task 7: Verification Pass

**Files:**
- No code changes expected.
- Physical iPhone required for background behavior.

- [ ] **Step 1: Run focused logic tests**

Run:

```bash
xcodebuild test -project Loqi.xcodeproj -scheme Loqi -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LoqiTests/ModelFileDownloaderTests -only-testing:LoqiTests/HuggingFaceBackgroundDownloaderTests -jobs 1
```

Expected: PASS.

- [ ] **Step 2: Run a constrained build**

Run:

```bash
xcodebuild build -project Loqi.xcodeproj -scheme Loqi -jobs 1
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Real iPhone SenseVoice check**

Manual steps:

```text
1. Install/run Loqi on a physical iPhone from Xcode.
2. Open Settings -> Speech recognition.
3. Start a SenseVoice download from ModelScope or Hugging Face.
4. Lock the phone or send Loqi to the background for 3 minutes.
5. Reopen Loqi.
```

Expected: progress advanced while Loqi was backgrounded, or the model finished installing. Do not count simulator behavior as proof.

- [ ] **Step 4: Real iPhone LLM check**

Manual steps:

```text
1. Remove the selected LLM snapshot if it is already installed.
2. Start an explicit model download from Settings or an AI feature consent prompt.
3. Send Loqi to the background for 5 minutes.
4. Reopen Loqi.
```

Expected: progress catches up or the model is installed. If iOS deferred network work because of Low Power Mode or network policy, Loqi shows no false completion and resumes progress when the system allows transfer.

- [ ] **Step 5: Real iPhone cancel check**

Manual steps:

```text
1. Start a large model download.
2. Tap the existing Stop/Cancel control.
3. Background Loqi for 1 minute.
4. Reopen Loqi.
```

Expected: the download remains stopped; a later retry starts cleanly and existing completed files are reused where the store already supports that.

- [ ] **Step 6: Commit verification notes if docs changed**

If README or `todo.md` verification lines are updated, commit them:

```bash
git add README.md todo.md
git commit -m "docs: record background download verification"
```

If no docs changed, skip this commit.

---

## Self-Review

- Spec coverage: background transfer helper, existing stores, LLM Hugging Face path, app delegate wakeup, cancellation, and real-device verification are covered.
- Non-goals preserved: no BGTask scheduler, no background ML execution, no UI redesign, and no consent change.
- Type consistency: `ModelFileDownloader`, `BackgroundModelDownloader`, and `HuggingFaceBackgroundDownloader` are introduced before later tasks reference them.
- Risk left explicit: simulator tests cover routing and snapshot logic only; physical iPhone verification proves actual iOS background behavior.
