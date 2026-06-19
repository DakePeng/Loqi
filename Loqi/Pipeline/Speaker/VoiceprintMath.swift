import Foundation

/// Pure embedding math, separated from the CoreML plumbing so it's
/// unit-testable. Clustering now lives in the diarizers themselves (offline
/// VBx, live Sortformer); these are the small general helpers that remain.
enum VoiceprintMath {
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, normA: Double = 0, normB: Double = 0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            normA += Double(a[i]) * Double(a[i])
            normB += Double(b[i]) * Double(b[i])
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Running mean of embeddings — the speaker profile centroid.
    static func updatedCentroid(
        _ centroid: [Float], count: Int, adding embedding: [Float]
    ) -> [Float] {
        guard centroid.count == embedding.count, count > 0 else { return embedding }
        let n = Float(count)
        return zip(centroid, embedding).map { ($0 * n + $1) / (n + 1) }
    }
}
