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

#if os(iOS)
struct BackgroundModelDownloader: Sendable {
    static let shared = BackgroundModelDownloader()

    func download(
        url: URL,
        to destination: URL,
        expectedBytes: Int64,
        sha256: String? = nil,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        throw URLError(.unsupportedURL)
    }
}
#endif
