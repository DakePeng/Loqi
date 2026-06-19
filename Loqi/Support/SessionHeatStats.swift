import Foundation

/// Per-session active-time tally for the two heavy compute paths, so the
/// Diagnostics screen can answer "is SenseVoice or the LLM driving heat?"
/// with a number instead of a guess. Active seconds, not wall seconds:
/// each path adds only the time it spent computing.
struct SessionHeatStats: Equatable {
    private(set) var llmActiveSeconds: Double = 0
    private(set) var asrActiveSeconds: Double = 0

    mutating func add(llm seconds: Double) { llmActiveSeconds += max(0, seconds) }
    mutating func add(asr seconds: Double) { asrActiveSeconds += max(0, seconds) }

    /// "LLM" / "ASR" when one clearly leads, "≈" when within 20%, "—" when idle.
    static func dominant(llmSeconds: Double, asrSeconds: Double) -> String {
        let total = llmSeconds + asrSeconds
        guard total > 0 else { return "—" }
        let lead = abs(llmSeconds - asrSeconds)
        if lead < 0.2 * max(llmSeconds, asrSeconds) { return "≈" }
        return llmSeconds > asrSeconds ? "LLM" : "ASR"
    }
}
