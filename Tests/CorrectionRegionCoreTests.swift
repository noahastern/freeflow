import Foundation

/// Synthetic field values only.
enum CorrectionRegionCoreTests {
    static func run() {
        testLocatesInsertionAtCaret()
        testRegionSurvivesTypingBeforeAndAfter()
        testEditedRegionIsReturned()
        testAnchorEditsAndAmbiguityAbort()
        testRegionDeleted()
        testFieldBoundariesAndEmojiOffsets()
        testLimitsAndExclusions()
    }

    private static func region(_ value: String, _ anchors: CorrectionAnchors) -> String? {
        guard case .region(let range) = CorrectionRegionCore.extractRegion(from: value, anchors: anchors) else { return nil }
        return (value as NSString).substring(with: range)
    }

    private static func anchors(_ value: String, inserted: String) -> CorrectionAnchors {
        let range = (value as NSString).range(of: inserted)
        return CorrectionRegionCore.makeAnchors(value: value, insertedRange: range)!
    }

    private static func testLocatesInsertionAtCaret() {
        let inserted = "ask grok about it."
        let value = "Earlier note: ask grok about it. Then ask grok about it. More"
        let secondEnd = (value as NSString).range(of: "ask grok about it.", options: .backwards).location + inserted.utf16.count
        // The caret disambiguates repeated text, including after the appended space.
        TestSupport.expectEqual(
            CorrectionRegionCore.locateInsertion(of: inserted, in: value, caret: secondEnd),
            NSRange(location: secondEnd - inserted.utf16.count, length: inserted.utf16.count)
        )
        TestSupport.expectEqual(
            CorrectionRegionCore.locateInsertion(of: inserted, in: value, caret: secondEnd + 1),
            NSRange(location: secondEnd - inserted.utf16.count, length: inserted.utf16.count)
        )
        TestSupport.expect(
            CorrectionRegionCore.locateInsertion(of: inserted, in: value, caret: nil) == nil,
            "Two copies without a caret must be ambiguous"
        )
        TestSupport.expectEqual(
            CorrectionRegionCore.locateInsertion(of: "only once", in: "this appears only once here", caret: 0),
            NSRange(location: 13, length: 9)
        )
        TestSupport.expect(
            CorrectionRegionCore.locateInsertion(of: "missing text", in: "nothing here", caret: 3) == nil,
            "Absent text must not be located"
        )
    }

    private static func testRegionSurvivesTypingBeforeAndAfter() {
        let inserted = "Deploy it to Cooper Netties."
        let value = "Status update for the synthetic team. \(inserted) Signed, Example"
        let fixed = anchors(value, inserted: inserted)
        TestSupport.expectEqual(region(value, fixed), inserted)

        // Words typed between the prefix anchor and the dictation join the region, and the
        // diff core then refuses them as an insertion rather than learning anything.
        let typedBefore = "Status update for the synthetic team. Extra words typed above. \(inserted) Signed, Example"
        let grownRegion = region(typedBefore, fixed)
        TestSupport.expectEqual(grownRegion, "Extra words typed above. \(inserted)")
        TestSupport.expectEqual(
            VocabularyCorrectionCore.evaluate(inserted: inserted, edited: grownRegion ?? ""),
            .none(reason: .insertion)
        )

        let typedFarBefore = "Hello! Status update for the synthetic team. \(inserted) Signed, Example"
        TestSupport.expectEqual(region(typedFarBefore, fixed), inserted)

        let typedAfter = "Status update for the synthetic team. \(inserted) Signed, Example\nP.S. more"
        TestSupport.expectEqual(region(typedAfter, fixed), inserted)
    }

    private static func testEditedRegionIsReturned() {
        let inserted = "Deploy it to Cooper Netties."
        let value = "Prefix sentence goes right here. \(inserted) Suffix sentence goes right here."
        let fixed = anchors(value, inserted: inserted)
        let edited = "Prefix sentence goes right here. Deploy it to Kubernetes. Suffix sentence goes right here."
        TestSupport.expectEqual(region(edited, fixed), "Deploy it to Kubernetes.")
    }

    private static func testAnchorEditsAndAmbiguityAbort() {
        let inserted = "grok is fast"
        let value = "Prefix sentence goes right here. \(inserted). Suffix sentence goes right here."
        let fixed = anchors(value, inserted: inserted)

        let prefixEdited = "Prefix sentence went right here. \(inserted). Suffix sentence goes right here."
        TestSupport.expectEqual(
            CorrectionRegionCore.extractRegion(from: prefixEdited, anchors: fixed),
            .failure(.prefixMissing)
        )
        let suffixEdited = "Prefix sentence goes right here. \(inserted). Suffix sentence went right here."
        TestSupport.expectEqual(
            CorrectionRegionCore.extractRegion(from: suffixEdited, anchors: fixed),
            .failure(.suffixMissing)
        )
        let duplicated = "Prefix sentence goes right here. \(inserted). Prefix sentence goes right here. \(inserted). Suffix sentence goes right here."
        TestSupport.expectEqual(
            CorrectionRegionCore.extractRegion(from: duplicated, anchors: fixed),
            .failure(.prefixAmbiguous)
        )
    }

    private static func testRegionDeleted() {
        let inserted = "grok is fast"
        let value = "Prefix sentence goes right here. \(inserted). Suffix sentence goes right here."
        let fixed = anchors(value, inserted: inserted)
        TestSupport.expectEqual(region("Prefix sentence goes right here. . Suffix sentence goes right here.", fixed), "")
        TestSupport.expectEqual(
            CorrectionRegionCore.extractRegion(from: "", anchors: fixed),
            .failure(.prefixMissing)
        )
    }

    private static func testFieldBoundariesAndEmojiOffsets() {
        // Region at the very start and end of the field: no anchors on that side.
        let whole = "grok is fast"
        let wholeAnchors = anchors(whole, inserted: whole)
        TestSupport.expectEqual(wholeAnchors.prefix.length, 0)
        TestSupport.expectEqual(wholeAnchors.suffix.length, 0)
        TestSupport.expectEqual(region("Groq is fast and cheap", wholeAnchors), "Groq is fast and cheap")

        let inserted = "ask grok 👍🏽 now"
        let value = "🎉🎉 日本語のメモ \(inserted) 🚀 末尾"
        let fixed = anchors(value, inserted: inserted)
        let edited = "🎉🎉 日本語のメモ ask Groq 👍🏽 now 🚀 末尾"
        let range: NSRange
        if case .region(let found) = CorrectionRegionCore.extractRegion(from: edited, anchors: fixed) {
            range = found
        } else {
            TestSupport.expect(false, "Emoji and CJK anchors must still locate the region")
            return
        }
        TestSupport.expectEqual(range.location, ("🎉🎉 日本語のメモ " as NSString).length)
        TestSupport.expectEqual((edited as NSString).substring(with: range), "ask Groq 👍🏽 now")
        TestSupport.expect(Range(range, in: edited) != nil, "Region must fall on character boundaries")
    }

    private static func testLimitsAndExclusions() {
        let big = String(repeating: "a", count: CorrectionRegionCore.maxFieldLength + 1)
        let fixed = anchors("before grok after", inserted: "grok")
        TestSupport.expectEqual(CorrectionRegionCore.extractRegion(from: big, anchors: fixed), .failure(.fieldTooLarge))
        TestSupport.expect(CorrectionRegionCore.locateInsertion(of: "a", in: big, caret: 1) == nil, "Oversized fields are never read")

        let grown = "before " + String(repeating: "x ", count: 400) + "after"
        let shortAnchors = anchors("before grok after", inserted: "grok")
        TestSupport.expectEqual(CorrectionRegionCore.extractRegion(from: grown, anchors: shortAnchors), .failure(.regionTooLarge))

        for bundle in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
                       "dev.warp.Warp-Stable", "com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess"] {
            TestSupport.expect(CorrectionRegionCore.isExcluded(bundleIdentifier: bundle, ownBundleIdentifier: nil), "\(bundle) must be excluded")
        }
        TestSupport.expect(CorrectionRegionCore.isExcluded(bundleIdentifier: nil, ownBundleIdentifier: nil), "Unknown apps must be excluded")
        TestSupport.expect(CorrectionRegionCore.isExcluded(bundleIdentifier: "com.example.self", ownBundleIdentifier: "com.example.self"), "FreeFlow's own fields must be excluded")
        TestSupport.expect(!CorrectionRegionCore.isExcluded(bundleIdentifier: "com.apple.TextEdit", ownBundleIdentifier: nil), "TextEdit must be watched")
    }
}
