import Foundation

/// Fingerprints of the text just before and just after an inserted dictation. Only lengths
/// and hashes are kept, never the surrounding field text itself.
struct CorrectionAnchors: Equatable {
    struct Fingerprint: Equatable {
        let length: Int
        let primary: UInt64
        let secondary: UInt64
    }

    let prefix: Fingerprint
    let suffix: Fingerprint
    let insertedLength: Int
}

/// Finds the dictated region inside a text field's current value. Pure: callers pass the
/// value they just read and discard it after each call.
enum CorrectionRegionCore {
    enum Failure: String, Equatable {
        case fieldTooLarge
        case prefixMissing
        case prefixAmbiguous
        case suffixMissing
        case suffixAmbiguous
        case regionTooLarge
        case invalidRange
    }

    enum Result: Equatable {
        case region(NSRange)
        case failure(Failure)
    }

    static let anchorLength = 32
    static let maxFieldLength = 50_000

    /// Terminals, password managers, and Keychain Access are never watched.
    static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "dev.warp.Warp-Preview",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
    ]

    static func isExcluded(bundleIdentifier: String?, ownBundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let bundleIdentifier else { return true }
        if let ownBundleIdentifier, bundleIdentifier == ownBundleIdentifier { return true }
        return excludedBundleIdentifiers.contains(bundleIdentifier)
    }

    // MARK: - Locating the insertion

    /// Finds the just-inserted text. Prefers the copy that ends at the caret (optionally
    /// followed by the single space FreeFlow appends after sentence punctuation); otherwise
    /// accepts a unique occurrence. Returns nil when absent or ambiguous.
    static func locateInsertion(of inserted: String, in value: String, caret: Int?) -> NSRange? {
        let units = Array(value.utf16)
        let needle = Array(inserted.utf16)
        guard !needle.isEmpty, units.count <= maxFieldLength, needle.count <= units.count else { return nil }

        if let caret, caret >= 0, caret <= units.count {
            for end in [caret, caret - 1] where end >= needle.count && end <= units.count {
                if end == caret - 1, units[end] != 0x20 { continue }
                if Array(units[(end - needle.count)..<end]) == needle {
                    let range = NSRange(location: end - needle.count, length: needle.count)
                    return Range(range, in: value) == nil ? nil : range
                }
            }
        }

        var found: NSRange?
        var start = 0
        while start + needle.count <= units.count {
            if units[start] == needle[0], Array(units[start..<(start + needle.count)]) == needle {
                guard found == nil else { return nil }
                found = NSRange(location: start, length: needle.count)
            }
            start += 1
        }
        guard let found, Range(found, in: value) != nil else { return nil }
        return found
    }

    // MARK: - Anchors

    static func makeAnchors(value: String, insertedRange: NSRange) -> CorrectionAnchors? {
        let units = Array(value.utf16)
        guard units.count <= maxFieldLength,
              insertedRange.location >= 0, insertedRange.length > 0,
              NSMaxRange(insertedRange) <= units.count else { return nil }
        let prefixLength = min(anchorLength, insertedRange.location)
        let suffixStart = NSMaxRange(insertedRange)
        let suffixLength = min(anchorLength, units.count - suffixStart)
        return CorrectionAnchors(
            prefix: fingerprint(units[(insertedRange.location - prefixLength)..<insertedRange.location]),
            suffix: fingerprint(units[suffixStart..<(suffixStart + suffixLength)]),
            insertedLength: insertedRange.length
        )
    }

    /// Locates the region between the anchors in the current value. Text typed before the
    /// region simply shifts it; edits that touch an anchor or make it ambiguous abort.
    static func extractRegion(from value: String, anchors: CorrectionAnchors) -> Result {
        let units = Array(value.utf16)
        guard units.count <= maxFieldLength else { return .failure(.fieldTooLarge) }

        let start: Int
        if anchors.prefix.length == 0 {
            start = 0
        } else {
            let matches = matchPositions(of: anchors.prefix, in: units, from: 0, limit: 2)
            guard let first = matches.first else { return .failure(.prefixMissing) }
            guard matches.count == 1 else { return .failure(.prefixAmbiguous) }
            start = first + anchors.prefix.length
        }

        let end: Int
        if anchors.suffix.length == 0 {
            end = units.count
        } else {
            let matches = matchPositions(of: anchors.suffix, in: units, from: start, limit: 2)
            guard let first = matches.first else { return .failure(.suffixMissing) }
            guard matches.count == 1 else { return .failure(.suffixAmbiguous) }
            end = first
        }

        guard end >= start else { return .failure(.invalidRange) }
        let range = NSRange(location: start, length: end - start)
        guard range.length <= maxRegionLength(insertedLength: anchors.insertedLength) else {
            return .failure(.regionTooLarge)
        }
        guard Range(range, in: value) != nil else { return .failure(.invalidRange) }
        return .region(range)
    }

    static func maxRegionLength(insertedLength: Int) -> Int {
        insertedLength * 3 + 256
    }

    /// Stable fingerprint of a region, used to notice changes without keeping the text.
    static func regionFingerprint(_ text: String) -> CorrectionAnchors.Fingerprint {
        let units = Array(text.utf16)
        return fingerprint(units[0..<units.count])
    }

    // MARK: - Hashing

    private static let primaryBase: UInt64 = 1_000_003
    private static let secondaryBase: UInt64 = 911_382_323

    private static func fingerprint(_ units: ArraySlice<UInt16>) -> CorrectionAnchors.Fingerprint {
        var primary: UInt64 = 0
        var secondary: UInt64 = 0
        for unit in units {
            primary = primary &* primaryBase &+ UInt64(unit) &+ 1
            secondary = secondary &* secondaryBase &+ UInt64(unit) &+ 1
        }
        return CorrectionAnchors.Fingerprint(length: units.count, primary: primary, secondary: secondary)
    }

    /// Rolling-hash search for start positions whose window matches the fingerprint.
    private static func matchPositions(
        of target: CorrectionAnchors.Fingerprint, in units: [UInt16], from lowerBound: Int, limit: Int
    ) -> [Int] {
        let length = target.length
        guard length > 0, lowerBound >= 0, lowerBound + length <= units.count else { return [] }
        var primaryPower: UInt64 = 1
        var secondaryPower: UInt64 = 1
        for _ in 1..<length {
            primaryPower = primaryPower &* primaryBase
            secondaryPower = secondaryPower &* secondaryBase
        }

        let window = fingerprint(units[lowerBound..<(lowerBound + length)])
        var primary = window.primary
        var secondary = window.secondary
        var positions: [Int] = []
        var position = lowerBound
        while true {
            if primary == target.primary, secondary == target.secondary {
                positions.append(position)
                if positions.count >= limit { return positions }
            }
            let next = position + length
            guard next < units.count else { break }
            let outgoing = UInt64(units[position]) &+ 1
            let incoming = UInt64(units[next]) &+ 1
            primary = (primary &- outgoing &* primaryPower) &* primaryBase &+ incoming
            secondary = (secondary &- outgoing &* secondaryPower) &* secondaryBase &+ incoming
            position += 1
        }
        return positions
    }
}
