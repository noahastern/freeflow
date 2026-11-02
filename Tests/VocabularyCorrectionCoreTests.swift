import Foundation

/// All text here is invented; none comes from a real dictation.
enum VocabularyCorrectionCoreTests {
    static func run() {
        testAcceptsSoundAlikeFixes()
        testRejectsEditsThatAreNotMisrecognitions()
        testAppendedTextIsContinuedTyping()
        testDuplicateAndRemovedPairsAreNotRelearned()
        testCaseChanges()
        testTokenOffsetsAreUTF16()
        testPhoneticKey()
    }

    private static func candidate(_ inserted: String, _ edited: String) -> VocabularyCorrectionCore.Outcome {
        VocabularyCorrectionCore.evaluate(inserted: inserted, edited: edited)
    }

    private static func testAcceptsSoundAlikeFixes() {
        TestSupport.expectEqual(
            candidate("Let's deploy the demo to Cooper Netties tomorrow.", "Let's deploy the demo to Kubernetes tomorrow."),
            .candidate(heard: "Cooper Netties", meant: "Kubernetes")
        )
        TestSupport.expectEqual(
            candidate("The new model from and tropic looks fast.", "The new model from Anthropic looks fast."),
            .candidate(heard: "and tropic", meant: "Anthropic")
        )
        TestSupport.expectEqual(
            candidate("Can we route this through grok instead?", "Can we route this through Groq instead?"),
            .candidate(heard: "grok", meant: "Groq")
        )
        // Short dictations still learn a single fixed word.
        TestSupport.expectEqual(candidate("grok", "Groq"), .candidate(heard: "grok", meant: "Groq"))
        // Trailing punctuation is not part of the pair.
        TestSupport.expectEqual(
            candidate("Ship it to Cooper Netties, then test.", "Ship it to Kubernetes, then test."),
            .candidate(heard: "Cooper Netties", meant: "Kubernetes")
        )
        TestSupport.expectEqual(
            candidate("Open the profile in insight systems now.", "Open the profile in Nsight systems now."),
            .candidate(heard: "insight", meant: "Nsight")
        )
    }

    private static func testRejectsEditsThatAreNotMisrecognitions() {
        func reason(_ inserted: String, _ edited: String) -> VocabularyCorrectionCore.Reason? {
            if case .none(let reason) = candidate(inserted, edited) { return reason }
            return nil
        }
        TestSupport.expectEqual(
            reason("We should meet tomorrow at noon to plan.", "Let's push the planning call to Friday."),
            .rewording
        )
        TestSupport.expectEqual(
            reason("I think we can ship it today because the tests pass.", "I think we can ship it today."),
            .deletion
        )
        TestSupport.expectEqual(reason("Please send the summary to the team today.", "Please send the summary today."), .deletion)
        TestSupport.expectEqual(reason("Tests run on every merge.", "Tests running on every merge."), .inflection)
        TestSupport.expectEqual(reason("The build is green and the deploy is done.", "The bild is green and the deploi is done."), .multipleHunks)
        TestSupport.expectEqual(reason("OK, that works for me.", "Okay, that works for me."), .commonWordSwap)
        TestSupport.expectEqual(reason("Send it to Sam today.", "Send it to Sam today."), .unchanged)
        TestSupport.expectEqual(reason("Put it in the folder please.", "Put it in the big folder please."), .insertion)
        TestSupport.expectEqual(reason("The total was about forty two hundred dollars.", "The total was about 4200 dollars."), .notWords)
        TestSupport.expectEqual(reason("Please email me at example dot test later this week.", "Please email me at a@example.test later this week."), .urlOrEmail)
        TestSupport.expectEqual(reason("Order the blue widget for the lab.", "Order the cheap widget for the lab."), .notSimilar)
        TestSupport.expectEqual(reason("Meet me at the cafe at nine.", "Meet me at the ab at nine."), .tooShort)
        TestSupport.expectEqual(reason("", "Kubernetes"), .empty)
    }

    private static func testAppendedTextIsContinuedTyping() {
        TestSupport.expectEqual(
            candidate("Deploy it to Cooper Netties.", "Deploy it to Cooper Netties. Then check the dashboards and logs."),
            .none(reason: .unchanged)
        )
        TestSupport.expectEqual(
            candidate("Deploy it to Cooper Netties.", "Deploy it to Kubernetes. Then check the dashboards."),
            .candidate(heard: "Cooper Netties", meant: "Kubernetes")
        )
    }

    private static func testDuplicateAndRemovedPairsAreNotRelearned() {
        let key = VocabularyCorrectionCore.KnownPairs.key(heard: "Grok", meant: "Groq")
        TestSupport.expectEqual(
            VocabularyCorrectionCore.evaluate(
                inserted: "Ask grok about it.", edited: "Ask Groq about it.",
                known: VocabularyCorrectionCore.KnownPairs(learned: [key])
            ),
            .none(reason: .alreadyLearned)
        )
        TestSupport.expectEqual(
            VocabularyCorrectionCore.evaluate(
                inserted: "Ask grok about it.", edited: "Ask Groq about it.",
                known: VocabularyCorrectionCore.KnownPairs(removed: [key])
            ),
            .none(reason: .previouslyRemoved)
        )
    }

    private static func testCaseChanges() {
        TestSupport.expectEqual(
            candidate("We profile with nsight every week.", "We profile with Nsight every week."),
            .candidate(heard: "nsight", meant: "Nsight")
        )
        TestSupport.expectEqual(
            candidate("Open the github page for it.", "Open the GitHub page for it."),
            .candidate(heard: "github", meant: "GitHub")
        )
        TestSupport.expectEqual(
            candidate("the meeting moved to friday afternoon.", "The meeting moved to friday afternoon."),
            .none(reason: .caseChangeOfCommonWord)
        )
    }

    private static func testTokenOffsetsAreUTF16() {
        let text = "🚀 ship 日本語テキスト to grok, «now»"
        let tokens = VocabularyCorrectionCore.tokenize(text)
        // Emoji-only words carry no letters and are skipped.
        TestSupport.expectEqual(tokens.map(\.text), ["ship", "日本語テキスト", "to", "grok", "now"])
        let nsText = text as NSString
        for token in tokens {
            TestSupport.expectEqual(nsText.substring(with: token.range), token.text)
        }
        TestSupport.expectEqual(tokens[0].range, NSRange(location: 3, length: 4))
        TestSupport.expectEqual(
            candidate("🎉 日本語 ask grok 👍🏽 today", "🎉 日本語 ask Groq 👍🏽 today"),
            .candidate(heard: "grok", meant: "Groq")
        )
    }

    private static func testPhoneticKey() {
        TestSupport.expectEqual(VocabularyCorrectionCore.consonantSkeleton("Cooper Netties"), "KPRNTS")
        TestSupport.expectEqual(VocabularyCorrectionCore.consonantSkeleton("Kubernetes"), "KPRNTS")
        TestSupport.expectEqual(
            VocabularyCorrectionCore.consonantSkeleton("and tropic"),
            VocabularyCorrectionCore.consonantSkeleton("Anthropic")
        )
        TestSupport.expect(VocabularyCorrectionCore.soundsOrLooksAlike("grok", "Groq"), "grok and Groq must match")
        TestSupport.expect(!VocabularyCorrectionCore.soundsOrLooksAlike("blue", "cheap"), "Unrelated words must not match")
    }
}
