import Foundation

/// "Learn from my corrections" is on unless the user turns it off.
enum LearnFromCorrectionsPreference {
    static let storageKey = "learn_from_corrections_enabled"
    static let defaultEnabled = true

    static func load(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: storageKey) as? Bool) ?? defaultEnabled
    }
}

/// One learned pair: what speech recognition produced and what the user meant.
/// Only the two phrases are kept; no surrounding text, app, or window is ever stored.
struct LearnedCorrection: Codable, Equatable, Identifiable {
    var id: UUID
    var heard: String
    var meant: String
    /// Times the pair was detected or applied.
    var count: Int
    /// Last time the pair was detected or applied; drives least-recently-used eviction.
    var lastUsed: Date
    /// Removed pairs are kept as tombstones so the same correction is not learned again.
    var isRemoved: Bool

    var key: String { VocabularyCorrectionCore.KnownPairs.key(heard: heard, meant: meant) }
}

/// Local, capped list of learned corrections. Value type so every rule is testable
/// without UserDefaults; `load`/`save` are the only storage boundary.
struct LearnedCorrectionList: Equatable {
    static let storageKey = "learned_corrections_v1"
    static let capacity = 200
    static let maxPhraseLength = 60

    private(set) var entries: [LearnedCorrection]

    init(entries: [LearnedCorrection] = []) {
        self.entries = entries
    }

    /// Learned pairs, most recently used first.
    var active: [LearnedCorrection] {
        entries.filter { !$0.isRemoved }.sorted { $0.lastUsed > $1.lastUsed }
    }

    var knownPairs: VocabularyCorrectionCore.KnownPairs {
        var known = VocabularyCorrectionCore.KnownPairs()
        for entry in entries {
            if entry.isRemoved {
                known.removed.insert(entry.key)
            } else {
                known.learned.insert(entry.key)
            }
        }
        return known
    }

    /// Adds a new pair. Returns nil when the pair is invalid, already learned (its count is
    /// bumped instead), or was removed by the user.
    @discardableResult
    mutating func learn(heard: String, meant: String, now: Date = Date()) -> LearnedCorrection? {
        let heard = Self.cleanedPhrase(heard)
        let meant = Self.cleanedPhrase(meant)
        guard !heard.isEmpty, !meant.isEmpty, heard != meant,
              heard.count <= Self.maxPhraseLength, meant.count <= Self.maxPhraseLength else { return nil }
        let key = VocabularyCorrectionCore.KnownPairs.key(heard: heard, meant: meant)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            guard !entries[index].isRemoved else { return nil }
            entries[index].count += 1
            entries[index].lastUsed = now
            return nil
        }
        let entry = LearnedCorrection(id: UUID(), heard: heard, meant: meant, count: 1, lastUsed: now, isRemoved: false)
        entries.append(entry)
        evictIfNeeded()
        return entries.contains(where: { $0.id == entry.id }) ? entry : nil
    }

    /// Removes a pair from use and remembers it so it is not learned again (Undo and remove).
    mutating func remove(id: UUID, now: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isRemoved = true
        entries[index].lastUsed = now
    }

    /// Forgets everything, including removed pairs, so the list starts over.
    mutating func clearAll() {
        entries.removeAll()
    }

    mutating func markApplied(ids: [UUID], now: Date = Date()) {
        guard !ids.isEmpty else { return }
        let applied = Set(ids)
        for index in entries.indices where applied.contains(entries[index].id) && !entries[index].isRemoved {
            entries[index].count += 1
            entries[index].lastUsed = now
        }
    }

    private mutating func evictIfNeeded() {
        guard entries.count > Self.capacity else { return }
        let overflow = entries.count - Self.capacity
        let oldest = entries
            .sorted { $0.lastUsed < $1.lastUsed }
            .prefix(overflow)
            .map(\.id)
        let evicted = Set(oldest)
        entries.removeAll { evicted.contains($0.id) }
    }

    static func cleanedPhrase(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .filter { !$0.isNewline && !($0.unicodeScalars.first.map(CharacterSet.controlCharacters.contains) ?? false) }
    }

    // MARK: - Storage

    static func load(from defaults: UserDefaults) -> LearnedCorrectionList {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([LearnedCorrection].self, from: data) else {
            return LearnedCorrectionList()
        }
        var list = LearnedCorrectionList(entries: entries)
        list.evictIfNeeded()
        return list
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
