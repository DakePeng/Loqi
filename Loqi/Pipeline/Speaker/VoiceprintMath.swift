import Foundation

/// Pure embedding math for speaker identification — separated from the
/// CoreML plumbing so it's unit-testable.
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

    /// Global diarization labels via average-linkage agglomerative
    /// clustering over ALL remembered utterance embeddings.
    ///
    /// Greedy online assignment proved fragile in both directions: a low
    /// join threshold merged two speakers, an eager-open strategy split one
    /// speaker into N. Re-clustering the whole memory makes the declared
    /// speaker count a CAP, not a target: clusters merge while their
    /// average similarity is at least `mergeThreshold`, then merging only
    /// continues (best pair first) until the cap is satisfied. One voice in
    /// the room yields one cluster no matter what N the user picked.
    ///
    /// Returns one label per embedding, numbered by first appearance.
    /// `singletonFloor`: a weak cluster is poor evidence for a distinct
    /// speaker — absorb it into its nearest cluster unless it is drastically
    /// dissimilar. Weak means a single utterance, or a pair of utterances
    /// that are both short (`durations` below `anchorSeconds`): embeddings
    /// from clips that short are noisy enough that two of them agreeing is
    /// still coincidence, so a short-spoken new voice needs a third
    /// corroborating utterance, while one utterance of `anchorSeconds`
    /// anchors a new speaker on the spot. Pass `durations: nil` to treat
    /// every utterance as anchored (singleton absorption only).
    static func agglomerativeLabels(
        embeddings: [[Float]],
        maxClusters: Int,
        mergeThreshold: Double = 0.30,
        singletonFloor: Double = 0.15,
        durations: [Double]? = nil,
        anchorSeconds: Double = 2.0
    ) -> [Int] {
        guard !embeddings.isEmpty else { return [] }
        let count = embeddings.count
        guard count > 1 else { return [0] }

        // Pairwise similarity matrix (memory is capped at ~60 utterances).
        var similarity = [[Double]](
            repeating: [Double](repeating: 0, count: count), count: count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                let s = cosineSimilarity(embeddings[i], embeddings[j])
                similarity[i][j] = s
                similarity[j][i] = s
            }
        }

        var clusters: [[Int]] = (0..<count).map { [$0] }

        func averageLinkage(_ a: [Int], _ b: [Int]) -> Double {
            var total = 0.0
            for i in a { for j in b { total += similarity[i][j] } }
            return total / Double(a.count * b.count)
        }

        while clusters.count > 1 {
            var bestPair = (0, 1)
            var bestScore = -Double.infinity
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let score = averageLinkage(clusters[i], clusters[j])
                    if score > bestScore {
                        bestScore = score
                        bestPair = (i, j)
                    }
                }
            }
            // Merge while genuinely similar; below that, only to satisfy
            // the user's speaker cap.
            guard bestScore >= mergeThreshold || clusters.count > maxClusters else {
                break
            }
            clusters[bestPair.0].append(contentsOf: clusters[bestPair.1])
            clusters.remove(at: bestPair.1)
        }

        // Corroboration pass: absorb weak clusters that aren't clearly a
        // different voice.
        func isWeak(_ members: [Int]) -> Bool {
            if members.count == 1 { return true }
            guard let durations else { return false }
            return members.count == 2
                && members.allSatisfy { durations[$0] < anchorSeconds }
        }
        var absorbed = true
        while absorbed, clusters.count > 1 {
            absorbed = false
            for index in clusters.indices where isWeak(clusters[index]) {
                var bestOther = -1
                var bestScore = -Double.infinity
                for other in clusters.indices where other != index {
                    let score = averageLinkage(clusters[index], clusters[other])
                    if score > bestScore {
                        bestScore = score
                        bestOther = other
                    }
                }
                if bestOther >= 0, bestScore >= singletonFloor {
                    clusters[bestOther].append(contentsOf: clusters[index])
                    clusters.remove(at: index)
                    absorbed = true
                    break
                }
            }
        }

        // Slot numbers by first appearance (earliest member index).
        let ordered = clusters.sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }
        var labels = [Int](repeating: 0, count: count)
        for (slot, members) in ordered.enumerated() {
            for member in members { labels[member] = slot }
        }
        return labels
    }

    /// Element-wise mean of embeddings — cosine similarity ignores scale,
    /// so no normalization is needed.
    static func meanEmbedding(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for embedding in embeddings where embedding.count == sum.count {
            for i in sum.indices { sum[i] += embedding[i] }
        }
        let n = Float(embeddings.count)
        return sum.map { $0 / n }
    }

    /// Give each cluster a stable slot number by matching its centroid
    /// against the slots' remembered centroids (greedy best pair first,
    /// each slot used once). Clusters that match nothing — similarity
    /// below `minSimilarity`, or all slots taken — mint new slots numbered
    /// `slots.count`, `slots.count + 1`, … in cluster order.
    ///
    /// This is what keeps "Speaker 2" meaning the same voice for a whole
    /// session: cluster indices from a fresh clustering pass are arbitrary,
    /// and a voice whose utterances all aged out of memory must reclaim its
    /// old number when it speaks again instead of being minted as new.
    static func matchClustersToSlots(
        clusters: [[Float]],
        slots: [[Float]],
        minSimilarity: Double = 0.20
    ) -> [Int] {
        var pairs: [(cluster: Int, slot: Int, score: Double)] = []
        for c in clusters.indices {
            for s in slots.indices {
                let score = cosineSimilarity(clusters[c], slots[s])
                if score >= minSimilarity {
                    pairs.append((c, s, score))
                }
            }
        }
        pairs.sort { $0.score > $1.score }

        var slotForCluster = [Int](repeating: -1, count: clusters.count)
        var usedSlots = Set<Int>()
        for pair in pairs
        where slotForCluster[pair.cluster] == -1 && !usedSlots.contains(pair.slot) {
            slotForCluster[pair.cluster] = pair.slot
            usedSlots.insert(pair.slot)
        }
        var nextSlot = slots.count
        for c in slotForCluster.indices where slotForCluster[c] == -1 {
            slotForCluster[c] = nextSlot
            nextSlot += 1
        }
        return slotForCluster
    }

    /// Decide which of two profiles a probe embedding belongs to.
    /// Returns nil when the call is too close to make confidently.
    static func classify(
        probe: [Float],
        candidates: [(id: String, centroid: [Float])],
        minSimilarity: Double = 0.25,
        minMargin: Double = 0.08
    ) -> String? {
        let scored = candidates
            .map { (id: $0.id, score: cosineSimilarity(probe, $0.centroid)) }
            .sorted { $0.score > $1.score }
        guard let best = scored.first, best.score >= minSimilarity else { return nil }
        if scored.count > 1, best.score - scored[1].score < minMargin { return nil }
        return best.id
    }
}
