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
