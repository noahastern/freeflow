import Foundation

/// How often cleanup reaches for one kind of written structure. `standard`
/// leaves the system prompt's own rules in charge.
enum FormattingAmount: String, CaseIterable, Codable, Identifiable {
    case less
    case standard
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .less: return "Less"
        case .standard: return "Default"
        case .more: return "More"
        }
    }
}

/// The pieces of layout and punctuation the user can turn up or down.
enum FormattingElement: String, CaseIterable, Codable, Identifiable {
    case paragraphBreaks
    case lists
    case parentheses
    case quotationMarks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paragraphBreaks: return "Paragraph breaks"
        case .lists: return "Lists"
        case .parentheses: return "Parentheses"
        case .quotationMarks: return "Quotation marks"
        }
    }

    /// Prompt instruction for a non-default amount, or nil for `standard`.
    func instruction(for amount: FormattingAmount) -> String? {
        switch (self, amount) {
        case (_, .standard):
            return nil
        case (.paragraphBreaks, .less):
            return "Paragraph breaks (less): start a new paragraph only for a clear change of topic. Keep related thoughts together in one paragraph, even across several sentences."
        case (.paragraphBreaks, .more):
            return "Paragraph breaks (more): start a new paragraph for each distinct point or shift in thought, so longer dictation reads as short paragraphs of one to three sentences."
        case (.lists, .less):
            return "Lists (less): use a list only when the speaker explicitly asks for one. Write spoken enumerations as prose sentences."
        case (.lists, .more):
            return "Lists (more): turn any enumeration of two or more separate items, steps, or options into a list, including a series inside one sentence when each item is more than a word or two."
        case (.parentheses, .less):
            return "Parentheses (less): write asides as part of the sentence, set off with commas, instead of in parentheses. Use parentheses only when the speaker dictates them."
        case (.parentheses, .more):
            return "Parentheses (more): put side remarks, clarifications, examples, and afterthoughts in parentheses whenever they interrupt or trail the main point."
        case (.quotationMarks, .less):
            return "Quotation marks (less): use quotation marks only for words someone is directly quoted as saying. Write labels, titles, and words discussed as words without quotation marks."
        case (.quotationMarks, .more):
            return "Quotation marks (more): also put quotation marks around button and menu names, titles, nicknames, terms being introduced or defined, and phrases the speaker uses ironically or at a distance."
        }
    }
}

struct FormattingPreferences: Codable, Equatable {
    static let storageKey = "formatting_preferences"

    /// Keyed by `FormattingElement.rawValue`. A missing entry is `standard`.
    var amounts: [String: FormattingAmount] = [:]

    init() {}

    /// Unknown or missing values fall back to defaults so newer settings still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amounts = (try? container.decodeIfPresent([String: FormattingAmount].self, forKey: .amounts)) ?? [:]
    }

    static func load(from defaults: UserDefaults) -> FormattingPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(FormattingPreferences.self, from: data) else {
            return FormattingPreferences()
        }
        return preferences
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func amount(for element: FormattingElement) -> FormattingAmount {
        amounts[element.rawValue] ?? .standard
    }

    /// Default amounts are left out so saved settings only hold real changes.
    mutating func setAmount(_ amount: FormattingAmount, for element: FormattingElement) {
        amounts[element.rawValue] = amount == .standard ? nil : amount
    }

    /// The system prompt addition, or "" when every element is at its default.
    var promptSection: String {
        let lines = FormattingElement.allCases.compactMap { element in
            element.instruction(for: amount(for: element)).map { "- " + $0 }
        }
        guard !lines.isEmpty else { return "" }
        return """
Formatting preferences. The speaker chose these; where they conflict with the formatting rules above, these win. They change layout and punctuation only, never the content.
\(lines.joined(separator: "\n"))
"""
    }
}
