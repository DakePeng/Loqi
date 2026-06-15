import Testing
@testable import Loqi

struct SpeechRunLimiterTests {
    /// #expect can't expand around mutating calls; evaluate first.
    private func split(
        _ limiter: inout SpeechRunLimiter, isSpeech: Bool, samples: Int
    ) -> Bool {
        limiter.shouldSplit(isSpeech: isSpeech, samples: samples)
    }

    @Test func splitsOnlyWhenRunReachesLimit() {
        var limiter = SpeechRunLimiter(limit: 1000)
        #expect(!split(&limiter, isSpeech: true, samples: 999))
        #expect(split(&limiter, isSpeech: true, samples: 1))
    }

    @Test func silenceResetsTheRun() {
        var limiter = SpeechRunLimiter(limit: 1000)
        #expect(!split(&limiter, isSpeech: true, samples: 999))
        #expect(!split(&limiter, isSpeech: false, samples: 512))
        // The dip reset the counter: a fresh run gets the full budget.
        #expect(!split(&limiter, isSpeech: true, samples: 999))
        #expect(split(&limiter, isSpeech: true, samples: 1))
    }

    @Test func restartsAfterForcedSplit() {
        var limiter = SpeechRunLimiter(limit: 100)
        #expect(split(&limiter, isSpeech: true, samples: 150))
        #expect(!split(&limiter, isSpeech: true, samples: 99))
        #expect(split(&limiter, isSpeech: true, samples: 1))
    }
}
