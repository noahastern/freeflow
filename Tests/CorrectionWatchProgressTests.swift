import Foundation

/// The learn-timing rules, driven with synthetic fingerprints.
enum CorrectionWatchProgressTests {
    static func run() {
        let inserted = CorrectionRegionCore.regionFingerprint("ask grok now")
        let halfTyped = CorrectionRegionCore.regionFingerprint("ask Gro now")
        let fixed = CorrectionRegionCore.regionFingerprint("ask Groq now")
        let pair = CorrectionWatchProgress.Pair(heard: "grok", meant: "Groq")
        let candidate: () -> VocabularyCorrectionCore.Outcome = { .candidate(heard: "grok", meant: "Groq") }
        let rejected: () -> VocabularyCorrectionCore.Outcome = { .none(reason: .notSimilar) }

        var progress = CorrectionWatchProgress(insertedFingerprint: inserted)
        TestSupport.expectEqual(progress.observe(regionFingerprint: inserted, evaluate: candidate), .keepWatching)
        TestSupport.expect(progress.pairOnStop(isTimeout: true) == nil, "An untouched region learns nothing")

        // Half-typed text keeps changing, so nothing is learned mid-word.
        TestSupport.expectEqual(progress.observe(regionFingerprint: halfTyped, evaluate: rejected), .keepWatching)
        TestSupport.expectEqual(progress.observe(regionFingerprint: fixed, evaluate: candidate), .keepWatching)
        TestSupport.expect(progress.pairOnStop(isTimeout: false) == nil, "A just-changed fix is not learned on an early stop")
        TestSupport.expectEqual(progress.pairOnStop(isTimeout: true), pair)
        TestSupport.expectEqual(progress.observe(regionFingerprint: fixed, evaluate: rejected), .keepWatching)
        TestSupport.expectEqual(progress.pairOnStop(isTimeout: false), pair)
        TestSupport.expectEqual(progress.observe(regionFingerprint: fixed, evaluate: rejected), .learn(pair))

        // Reverting the fix clears it.
        var reverted = CorrectionWatchProgress(insertedFingerprint: inserted)
        _ = reverted.observe(regionFingerprint: fixed, evaluate: candidate)
        _ = reverted.observe(regionFingerprint: inserted, evaluate: candidate)
        _ = reverted.observe(regionFingerprint: inserted, evaluate: candidate)
        TestSupport.expectEqual(reverted.observe(regionFingerprint: inserted, evaluate: candidate), .keepWatching)
        TestSupport.expect(reverted.pairOnStop(isTimeout: true) == nil, "A reverted fix is not learned")
    }
}
