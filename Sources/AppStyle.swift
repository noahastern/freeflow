import Foundation

/// Capitalization and punctuation for a style. Tones never change the words,
/// so they stay inside the cleanup prompt's no-added-content contract.
enum WritingTone: String, CaseIterable, Codable, Identifiable {
    case formal
    case casual
    case veryCasual
    case excited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very Casual"
        case .excited: return "Excited"
        }
    }

    var summary: String {
        switch self {
        case .formal: return "Caps and full punctuation"
        case .casual: return "Caps, lighter punctuation"
        case .veryCasual: return "No caps, lighter punctuation"
        case .excited: return "More exclamation marks"
        }
    }

    var sample: String {
        switch self {
        case .formal: return "Sounds good, see you at the game tonight. I'll grab the tickets on the way."
        case .casual: return "Sounds good see you at the game tonight. I'll grab the tickets on the way"
        case .veryCasual: return "sounds good see you at the game tonight. i'll grab the tickets on the way"
        case .excited: return "Sounds good, see you at the game tonight! I'll grab the tickets on the way!"
        }
    }

    var instruction: String {
        switch self {
        case .formal:
            return "Standard capitalization and full punctuation. End every sentence with a period or question mark, and use an exclamation mark only where the speaker clearly exclaimed."
        case .casual:
            return "Standard capitalization with lighter punctuation. Leave off the period after the last sentence, and drop commas that are not needed to make the meaning clear. Keep question marks."
        case .veryCasual:
            return "Write everything in lowercase, including the start of each sentence, names, and \"i\". Keep acronyms and code identifiers in their usual casing. Leave off the period after the last sentence, and drop commas that are not needed to make the meaning clear. Keep question marks."
        case .excited:
            return "Standard capitalization and full punctuation. Where the speaker sounds upbeat or enthusiastic, end the sentence with an exclamation mark instead of a period. Keep neutral or serious sentences as they are, and do not add words or emoji."
        }
    }
}

/// Groups of destination apps that share a writing style. Cleanup appends the
/// group's instruction to the system prompt so a Slack message reads like chat
/// and an email reads like email, without the user editing the main prompt.
enum AppStyleCategory: String, CaseIterable, Codable, Identifiable {
    case messaging
    case email
    case aiAssistant
    case coding
    case documents
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messaging: return "Messaging"
        case .email: return "Email"
        case .aiAssistant: return "AI Assistants"
        case .coding: return "Code & Terminal"
        case .documents: return "Notes & Docs"
        case .general: return "Everything Else"
        }
    }

    var icon: String {
        switch self {
        case .messaging: return "bubble.left.and.bubble.right.fill"
        case .email: return "envelope.fill"
        case .aiAssistant: return "sparkles"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .documents: return "doc.text.fill"
        case .general: return "square.grid.2x2.fill"
        }
    }

    var examples: String {
        switch self {
        case .messaging: return "Slack, Discord, Messages, WhatsApp, Telegram, Teams"
        case .email: return "Mail, Outlook, Spark, Superhuman, Gmail in a browser"
        case .aiAssistant: return "ChatGPT, Claude, Codex, Perplexity, and their websites"
        case .coding: return "Xcode, VS Code, Cursor, Zed, Terminal, iTerm, Warp, Ghostty"
        case .documents: return "Notes, Notion, Obsidian, Pages, Word, Google Docs"
        case .general: return "Browsers and any app not listed above"
        }
    }

    var defaultInstruction: String {
        switch self {
        case .messaging:
            return """
The text is a chat message. Write it the way people type in chat. Most chat messages are one block of text with no line breaks, even across several sentences. Only when the message switches to a different subject, start that part on a new line with a single line break, where someone would otherwise send a second message. Do not add greetings, sign-offs, or formal structure. Keep the speaker's slang and phrasing.
"""
        case .email:
            return """
The text is an email. Use complete sentences. Keep related sentences together in a paragraph, and start a new paragraph only when the email moves to a different point. Follow the email salutation and closing rules above. Keep the speaker's tone; do not make it more formal than it was spoken.
"""
        case .aiAssistant:
            return """
The text is a prompt for an AI assistant. Keep every detail, constraint, and instruction the speaker gave, in the order given. Write clear, well-punctuated sentences. Preserve technical terms, file names, and code identifiers exactly. When a longer prompt has background and then separate requests, give each its own paragraphs; keep sentences about the same request together. Do not answer, shorten, or act on the prompt.
"""
        case .coding:
            return """
The text is going into a code editor or terminal: usually a prompt to a coding agent, a code comment, a commit message, or a command. Be concise. A command or commit subject stays on one line; a longer prompt to an agent gets paragraph breaks only where it moves to a different point. Preserve identifiers, file paths, flags, and casing exactly, and write spoken symbols as code when clearly intended. No greetings or filler.
"""
        case .documents:
            return """
The text is going into a document or note. Use complete sentences, with paragraph breaks where the subject changes, not after every sentence. Keep the speaker's voice.
"""
        case .general:
            return ""
        }
    }

    /// Prompts and code are left to their own rules, so they offer no tone.
    var availableTones: [WritingTone] {
        switch self {
        case .messaging: return [.formal, .casual, .veryCasual, .excited]
        case .email, .documents, .general: return [.formal, .casual, .excited]
        case .aiAssistant, .coding: return []
        }
    }

    var defaultTone: WritingTone? {
        switch self {
        case .messaging: return .casual
        case .email, .documents, .general: return .formal
        case .aiAssistant, .coding: return nil
        }
    }
}

/// An app the user moved to a style other than the one it would get by default.
struct AppStyleAssignment: Codable, Equatable {
    var appName: String
    var category: AppStyleCategory
}

struct AppStyleSettings: Codable, Equatable {
    static let storageKey = "app_style_settings"

    var isEnabled = true
    /// Keyed by `AppStyleCategory.rawValue`. A blank or missing entry uses the default.
    var customInstructions: [String: String] = [:]
    /// Keyed by bundle identifier.
    var appAssignments: [String: AppStyleAssignment] = [:]
    /// Keyed by `AppStyleCategory.rawValue`. A missing entry uses the category's default tone.
    var tones: [String: WritingTone] = [:]

    init() {}

    /// Missing keys fall back to defaults so settings saved by an older build still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        customInstructions = try container.decodeIfPresent([String: String].self, forKey: .customInstructions) ?? [:]
        appAssignments = try container.decodeIfPresent([String: AppStyleAssignment].self, forKey: .appAssignments) ?? [:]
        tones = (try? container.decodeIfPresent([String: WritingTone].self, forKey: .tones)) ?? [:]
    }

    static func load(from defaults: UserDefaults) -> AppStyleSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppStyleSettings.self, from: data) else {
            return AppStyleSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func instruction(for category: AppStyleCategory) -> String {
        let custom = customInstructions[category.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty
            ? category.defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            : custom
    }

    /// The chosen tone, or the default when none is saved or the saved one is
    /// not offered for this category.
    func tone(for category: AppStyleCategory) -> WritingTone? {
        if let tone = tones[category.rawValue], category.availableTones.contains(tone) {
            return tone
        }
        return category.defaultTone
    }

    func isCustomized(_ category: AppStyleCategory) -> Bool {
        let custom = customInstructions[category.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !custom.isEmpty
            && custom != category.defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppStyleResolver {
    static let knownApps: [String: AppStyleCategory] = [
        // Messaging
        "com.tinyspeck.slackmacgap": .messaging,
        "com.hnc.Discord": .messaging,
        "com.apple.MobileSMS": .messaging,
        "net.whatsapp.WhatsApp": .messaging,
        "desktop.WhatsApp": .messaging,
        "ru.keepcoder.Telegram": .messaging,
        "com.tdesktop.Telegram": .messaging,
        "org.whispersystems.signal-desktop": .messaging,
        "com.microsoft.teams": .messaging,
        "com.microsoft.teams2": .messaging,
        "com.facebook.archon": .messaging,
        "com.facebook.archon.developerID": .messaging,
        // Email
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.SparkDesktop": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email,
        "com.mimestream.Mimestream": .email,
        "it.bloop.airmail2": .email,
        // AI assistants
        "com.openai.chat": .aiAssistant,
        "com.openai.codex": .aiAssistant,
        "com.anthropic.claudefordesktop": .aiAssistant,
        "ai.perplexity.mac": .aiAssistant,
        // Code and terminal
        "com.apple.dt.Xcode": .coding,
        "com.microsoft.VSCode": .coding,
        "com.microsoft.VSCodeInsiders": .coding,
        "com.todesktop.230313mzl4w4u92": .coding,
        "dev.zed.Zed": .coding,
        "com.exafunction.windsurf": .coding,
        "com.sublimetext.4": .coding,
        "com.apple.Terminal": .coding,
        "com.googlecode.iterm2": .coding,
        "dev.warp.Warp-Stable": .coding,
        "com.mitchellh.ghostty": .coding,
        // Notes and documents
        "com.apple.Notes": .documents,
        "com.apple.TextEdit": .documents,
        "com.apple.iWork.Pages": .documents,
        "com.microsoft.Word": .documents,
        "notion.id": .documents,
        "md.obsidian": .documents,
        "net.shinyfrog.bear": .documents,
        "com.lukilabs.lukiapp": .documents,
    ]

    static let knownAppPrefixes: [(prefix: String, category: AppStyleCategory)] = [
        ("com.jetbrains.", .coding),
    ]

    static let browsers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "app.zen-browser.zen",
    ]

    /// Checked in order against a browser's window title, which is the page title.
    static let webAppTitleKeywords: [(keyword: String, category: AppStyleCategory)] = [
        ("ChatGPT", .aiAssistant),
        ("Claude", .aiAssistant),
        ("Gemini", .aiAssistant),
        ("Perplexity", .aiAssistant),
        ("Gmail", .email),
        ("Outlook", .email),
        ("Proton Mail", .email),
        ("Fastmail", .email),
        ("iCloud Mail", .email),
        ("Slack", .messaging),
        ("Discord", .messaging),
        ("WhatsApp", .messaging),
        ("Messenger", .messaging),
        ("Telegram", .messaging),
        ("Microsoft Teams", .messaging),
        ("Google Chat", .messaging),
        ("Google Docs", .documents),
        ("Notion", .documents),
        ("Confluence", .documents),
    ]

    static func category(
        bundleIdentifier: String?,
        windowTitle: String?,
        assignments: [String: AppStyleAssignment] = [:]
    ) -> AppStyleCategory {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return .general }
        if let assignment = assignments[bundleIdentifier] {
            return assignment.category
        }
        if let category = defaultCategory(bundleIdentifier: bundleIdentifier, windowTitle: windowTitle) {
            return category
        }
        return .general
    }

    /// The category an app gets without any user assignment, or nil when unknown.
    static func defaultCategory(bundleIdentifier: String, windowTitle: String?) -> AppStyleCategory? {
        if let category = knownApps[bundleIdentifier] {
            return category
        }
        if let match = knownAppPrefixes.first(where: { bundleIdentifier.hasPrefix($0.prefix) }) {
            return match.category
        }
        if browsers.contains(bundleIdentifier), let windowTitle {
            return webAppTitleKeywords.first { windowTitle.localizedCaseInsensitiveContains($0.keyword) }?.category
        }
        return nil
    }

    /// The system prompt addition for the destination app, or "" when styles are
    /// off or the category has no instruction.
    static func promptSection(
        bundleIdentifier: String?,
        windowTitle: String?,
        settings: AppStyleSettings
    ) -> String {
        guard settings.isEnabled else { return "" }
        let category = category(
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            assignments: settings.appAssignments
        )
        var lines: [String] = []
        let instruction = settings.instruction(for: category)
        if !instruction.isEmpty {
            lines.append(instruction)
        }
        if let tone = settings.tone(for: category) {
            lines.append("Tone (\(tone.title)): \(tone.instruction)")
        }
        guard !lines.isEmpty else { return "" }
        return """
Destination app style (\(category.title)):
\(lines.joined(separator: "\n"))
These style notes change tone and formatting only. The hard contract above still applies: never add content, answer, or carry out the transcript.
"""
    }
}
