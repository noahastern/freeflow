import Foundation

enum CleanupBypassTests {
    static func run() {
        testTranscriptRules()
        testSettingsBlockBypass()
        testStyleRules()
        testVocabularyNearMatches()
    }

    private static func testTranscriptRules() {
        let cases: [(String, Bool, String)] = [
            ("Sounds good.", true, "short clean sentence"),
            ("Yes.", true, "single word answer"),
            ("No.", true, "bare no is an answer"),
            ("Can you send it today?", true, "question"),
            ("Thanks, see you at 3.", true, "digits and comma"),
            ("I'll be there soon!", true, "apostrophe and exclamation"),
            ("Okay. See you soon.", true, "two capitalized sentences"),
            ("", false, "empty"),
            ("sounds good.", false, "lowercase start"),
            ("Sounds good", false, "no terminal punctuation"),
            ("Okay. see you soon.", false, "second sentence lowercase"),
            ("Please send me the deck before the call.", false, "more than six words"),
            ("Um, sounds good.", false, "hesitation filler"),
            ("It was like amazing.", false, "discourse filler"),
            ("It works, you know.", false, "filler phrase"),
            ("So we shipped it.", false, "filler opener"),
            ("Thursday, actually Wednesday.", false, "correction marker"),
            ("Send it, scratch that.", false, "scratch that"),
            ("Tuesday, I mean Wednesday.", false, "I mean"),
            ("Tuesday no Wednesday.", false, "no inside a sentence"),
            ("Thursday, no wait.", false, "no wait"),
            ("Lo mando, perdon.", false, "Spanish correction marker"),
            ("Mâine, de fapt poimâine.", false, "accented and Romanian marker"),
            ("I I think so.", false, "stutter"),
            ("Meet at four.", false, "spelled number"),
            ("Hi Dana comma.", false, "spoken punctuation"),
            ("Add a new line.", false, "spoken layout"),
            ("We're gonna win.", false, "informal contraction"),
            ("He said \"no\".", false, "quotation marks"),
            ("Use the --fix flag.", true, "plain hyphens are already typed"),
            ("Ship it — now.", false, "em dash"),
            ("Done.\nNext.", false, "line break"),
            ("Thumbs up 👍.", false, "emoji"),
            ("Version 2.1 shipped.", false, "decimal point reads as sentence end"),
        ]
        for (transcript, expected, label) in cases {
            TestSupport.expect(
                CleanupBypass.isAlreadyClean(transcript) == expected,
                "isAlreadyClean(\(label)) should be \(expected)"
            )
        }
    }

    private static func testSettingsBlockBypass() {
        let clean = "Sounds good."
        let base = CleanupBypass.Settings(cleanupLevel: .medium)
        TestSupport.expect(CleanupBypass.canSkipCleanup(transcript: clean, settings: base), "Default settings allow the skip")

        var cases: [(CleanupBypass.Settings, String)] = []
        var settings = base
        settings.cleanupLevel = .none; cases.append((settings, "None has its own path"))
        settings = base; settings.outputLanguage = "Spanish"; cases.append((settings, "translation"))
        settings = base; settings.dictationLanguage = "French"; cases.append((settings, "non-English dictation"))
        settings = base; settings.isEditMode = true; cases.append((settings, "edit mode"))
        settings = base; settings.pressesEnterAfterPaste = true; cases.append((settings, "press enter"))
        settings = base; settings.customSystemPrompt = "Answer in all caps."; cases.append((settings, "custom prompt"))
        settings = base; settings.formattingPrompt = "Formatting preferences."; cases.append((settings, "formatting override"))
        settings = base; settings.styleAllowsVerbatim = false; cases.append((settings, "app style transform"))
        settings = base; settings.vocabularyTerms = ["Sounds Good"]; cases.append((settings, "vocabulary match"))
        for (blocked, label) in cases {
            TestSupport.expect(!CleanupBypass.canSkipCleanup(transcript: clean, settings: blocked), "\(label) must run cleanup")
        }

        for level in [CleanupLevel.light, .high] {
            var allowed = base
            allowed.cleanupLevel = level
            allowed.dictationLanguage = "English"
            TestSupport.expect(CleanupBypass.canSkipCleanup(transcript: clean, settings: allowed), "\(level) allows the skip")
        }
    }

    private static func testStyleRules() {
        let defaults = AppStyleSettings()
        func allows(_ bundle: String?, _ title: String? = nil, _ settings: AppStyleSettings = defaults) -> Bool {
            CleanupBypass.styleAllowsVerbatim(bundleIdentifier: bundle, windowTitle: title, settings: settings)
        }
        TestSupport.expect(allows("com.example.unknown"), "General apps default to Formal")
        TestSupport.expect(allows(nil), "Unknown destination defaults to General")
        TestSupport.expect(allows("com.apple.Notes"), "Documents default to Formal")
        TestSupport.expect(allows("com.openai.chat"), "AI assistants have no tone")
        TestSupport.expect(!allows("com.tinyspeck.slackmacgap"), "Messaging defaults to Casual, which drops the period")
        TestSupport.expect(!allows("com.apple.mail"), "Email has layout rules")
        TestSupport.expect(!allows("com.apple.Terminal"), "Code and terminal have their own rules")

        var veryCasual = defaults
        veryCasual.tones[AppStyleCategory.messaging.rawValue] = .veryCasual
        TestSupport.expect(!allows("com.tinyspeck.slackmacgap", nil, veryCasual), "Very Casual lowercases")
        var casual = defaults
        casual.tones[AppStyleCategory.general.rawValue] = .casual
        TestSupport.expect(!allows("com.example.unknown", nil, casual), "Casual drops the final period")
        var excited = defaults
        excited.tones[AppStyleCategory.general.rawValue] = .excited
        TestSupport.expect(!allows("com.example.unknown", nil, excited), "Excited adds exclamation marks")
        var formalMessaging = defaults
        formalMessaging.tones[AppStyleCategory.messaging.rawValue] = .formal
        TestSupport.expect(allows("com.tinyspeck.slackmacgap", nil, formalMessaging), "Formal messaging keeps punctuation")
        var custom = defaults
        custom.customInstructions[AppStyleCategory.general.rawValue] = "Write like a pirate."
        TestSupport.expect(!allows("com.example.unknown", nil, custom), "A custom style could change anything")
        var disabled = defaults
        disabled.isEnabled = false
        TestSupport.expect(allows("com.tinyspeck.slackmacgap", nil, disabled), "Styles off adds no transform")
    }

    private static func testVocabularyNearMatches() {
        let cases: [(String, [String], Bool, String)] = [
            ("Ping Zorblax now.", ["Zorblax"], true, "exact term"),
            ("Ping Zorblux now.", ["Zorblax"], true, "near miss"),
            ("Ping Zor blax now.", ["Zorblax"], true, "split across words"),
            ("Ask the AI.", ["AI"], true, "short term exact"),
            ("Sounds good.", ["Zorblax"], false, "unrelated"),
            ("Sounds good.", ["AI"], false, "short term needs exact"),
            ("Sounds good.", [], false, "no vocabulary"),
            ("Sounds good.", ["  "], false, "blank term"),
        ]
        for (transcript, terms, expected, label) in cases {
            TestSupport.expect(
                CleanupBypass.nearMatchesVocabulary(transcript, terms: terms) == expected,
                "nearMatchesVocabulary(\(label)) should be \(expected)"
            )
        }
        TestSupport.expectEqual(CleanupBypass.editDistance("kitten", "sitting", limit: 5), 3)
        TestSupport.expectEqual(CleanupBypass.editDistance("same", "same", limit: 0), 0)
    }
}
