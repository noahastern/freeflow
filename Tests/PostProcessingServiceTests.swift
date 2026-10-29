import Foundation

enum PostProcessingServiceTests {
    static func run() {
        testAutoDetectAndEnglishLeavePromptUnchanged()
        testSelectedLanguageIsNamed()
        testOutputLanguageTakesPrecedence()
        testCustomPromptKeepsDirective()
        testFallbackModelReceivesSameDirective()
        testEnglishRequestIsUnchanged()
        testAppStyleAndVocabularyReachRequest()
        testDefaultPromptAsksForParagraphBreaks()
        testLightCleanupReachesRequest()
    }

    private static func testLightCleanupReachesRequest() {
        let style = AppStyleResolver.promptSection(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            windowTitle: nil,
            settings: AppStyleSettings()
        )
        let requests = cleanupRequests(
            dictationLanguage: "English",
            appStylePrompt: style,
            cleanupLevel: .light
        ) { _ in "Synthetic cleaned text." }
        TestSupport.expectEqual(requests.count, 1)
        let prompt = requests[0].systemPrompt
        TestSupport.expect(prompt.hasPrefix(PostProcessingService.defaultSystemPrompt), "Cleanup level must only append to the base prompt")
        let levelRange = prompt.range(of: "Cleanup level: Light.")!
        let styleRange = prompt.range(of: "Destination app style")!
        TestSupport.expect(levelRange.lowerBound < styleRange.lowerBound, "Cleanup level must come before the app style")
    }

    // Regression: long multi-thought dictation came back as one paragraph
    // because the prompt never asked for the line breaks a typist would add.
    private static func testDefaultPromptAsksForParagraphBreaks() {
        let prompt = PostProcessingService.defaultSystemPrompt
        TestSupport.expect(prompt.contains("Paragraphs and line breaks:"), "Default prompt must have a paragraph section")
        TestSupport.expect(prompt.contains("Line breaks and paragraph breaks are layout, not added content."), "Hard contract must allow line breaks")
        TestSupport.expect(
            prompt.contains("new workout routine.\n\n    I'm excited for tomorrow's workout"),
            "Paragraph example must show a real blank line"
        )
        TestSupport.expect(!prompt.contains("\\n"), "Prompt must not show a literal backslash-n the model could copy")
        TestSupport.expect(!prompt.contains("for short messages"), "Prompt must not frame every dictation as a short message")
    }

    private static let directive = "The dictation is primarily in Russian"

    private static func testAutoDetectAndEnglishLeavePromptUnchanged() {
        for language in ["", "  ", "English"] {
            TestSupport.expectEqual(
                PostProcessingService.cleanupSystemPrompt(
                    customSystemPrompt: "",
                    outputLanguage: "",
                    dictationLanguage: language
                ),
                PostProcessingService.defaultSystemPrompt
            )
        }
    }

    private static func testSelectedLanguageIsNamed() {
        let prompt = PostProcessingService.cleanupSystemPrompt(
            customSystemPrompt: "",
            outputLanguage: "",
            dictationLanguage: "Russian"
        )
        TestSupport.expect(prompt.hasPrefix(PostProcessingService.defaultSystemPrompt), "Directive must only append")
        TestSupport.expect(prompt.contains(directive), "Selected language must be named")
        TestSupport.expect(prompt.contains("Write the cleaned text in Russian"), "Output language must be named")
        TestSupport.expect(
            prompt.contains("Preserve mixed-language words and spans in their original languages"),
            "Naming a language must not override mixed-language preservation"
        )
        TestSupport.expect(!prompt.contains("Translate the final cleaned text"), "Keeping a language must not translate")
    }

    private static func testOutputLanguageTakesPrecedence() {
        let prompt = PostProcessingService.cleanupSystemPrompt(
            customSystemPrompt: "",
            outputLanguage: "German",
            dictationLanguage: "Russian"
        )
        TestSupport.expectEqual(
            prompt,
            PostProcessingService.applyOutputLanguage(PostProcessingService.defaultSystemPrompt, language: "German")
        )
        TestSupport.expect(!prompt.contains(directive), "Output Language must replace the dictation directive")
    }

    private static func testCustomPromptKeepsDirective() {
        let prompt = PostProcessingService.cleanupSystemPrompt(
            customSystemPrompt: "Synthetic custom prompt.",
            outputLanguage: "",
            dictationLanguage: "Russian"
        )
        TestSupport.expect(prompt.hasPrefix("Synthetic custom prompt."), "Custom prompt must replace the default")
        TestSupport.expect(!prompt.contains(PostProcessingService.defaultSystemPrompt), "Default prompt must not leak in")
        TestSupport.expect(prompt.contains(directive), "Custom prompt must still get the directive")
    }

    private static func testFallbackModelReceivesSameDirective() {
        // The primary returns empty content, which retries once on the fallback model.
        let requests = cleanupRequests(dictationLanguage: "Russian") { model in
            model == "synthetic-primary" ? "" : "Synthetic cleaned text."
        }
        TestSupport.expectEqual(requests.map(\.model), ["synthetic-primary", "synthetic-fallback"])
        for request in requests {
            TestSupport.expect(request.systemPrompt.contains(directive), "\(request.model) must get the directive")
        }
        TestSupport.expectEqual(requests[0].systemPrompt, requests[1].systemPrompt)
    }

    private static func testEnglishRequestIsUnchanged() {
        let requests = cleanupRequests(dictationLanguage: "English") { _ in "Synthetic cleaned text." }
        TestSupport.expectEqual(requests.map(\.systemPrompt), [PostProcessingService.defaultSystemPrompt])
    }

    private static func testAppStyleAndVocabularyReachRequest() {
        let style = AppStyleResolver.promptSection(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            windowTitle: nil,
            settings: AppStyleSettings()
        )
        let requests = cleanupRequests(
            dictationLanguage: "English",
            customVocabulary: "Groq, Nsight",
            appStylePrompt: style
        ) { _ in "Synthetic cleaned text." }
        TestSupport.expectEqual(requests.count, 1)
        let request = requests[0]
        TestSupport.expect(request.systemPrompt.hasPrefix(PostProcessingService.defaultSystemPrompt), "App style must only append to the base prompt")
        TestSupport.expect(request.systemPrompt.contains("Destination app style (Messaging)"), "App style must reach the system prompt")
        TestSupport.expect(request.systemPrompt.contains("Personal dictionary"), "Vocabulary must reach the system prompt")
        let styleRange = request.systemPrompt.range(of: "Destination app style")!
        let vocabularyRange = request.systemPrompt.range(of: "Personal dictionary")!
        TestSupport.expect(styleRange.lowerBound < vocabularyRange.lowerBound, "Vocabulary must come after the app style, closest to the transcript")
        TestSupport.expect(
            request.userMessage.contains("PERSONAL_DICTIONARY (write sound-alike words with these exact spellings): Groq, Nsight"),
            "Vocabulary reminder must sit next to the transcript"
        )
    }

    // MARK: - Request capture

    private struct CapturedRequest {
        let model: String
        let systemPrompt: String
        let userMessage: String
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []

        func record(_ body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            bodies.append(body ?? Data())
        }

        var captured: [CapturedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return bodies.map { body in
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let messages = json["messages"] as? [[String: Any]] ?? []
                let system = messages.first { $0["role"] as? String == "system" }
                let user = messages.first { $0["role"] as? String == "user" }
                return CapturedRequest(
                    model: json["model"] as? String ?? "",
                    systemPrompt: system?["content"] as? String ?? "",
                    userMessage: user?["content"] as? String ?? ""
                )
            }
        }
    }

    private static func cleanupRequests(
        dictationLanguage: String,
        customVocabulary: String = "",
        appStylePrompt: String = "",
        cleanupLevel: CleanupLevel = .medium,
        reply: @escaping @Sendable (String) -> String
    ) -> [CapturedRequest] {
        let recorder = RequestRecorder()
        let service = PostProcessingService(
            apiKey: "synthetic-key",
            baseURL: "https://example.invalid/v1",
            preferredModel: "synthetic-primary",
            preferredFallbackModel: "synthetic-fallback",
            transport: { request in
                recorder.record(request.httpBody)
                let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let model = json?["model"] as? String ?? ""
                let body = try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": reply(model)]]]
                ])
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
        )
        let context = AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: nil,
            currentActivity: "",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: nil
        )

        let done = DispatchSemaphore(value: 0)
        Task {
            _ = try? await service.postProcess(
                transcript: "synthetic transcript",
                context: context,
                customVocabulary: customVocabulary,
                appStylePrompt: appStylePrompt,
                cleanupLevel: cleanupLevel,
                dictationLanguage: dictationLanguage
            )
            done.signal()
        }
        done.wait()
        return recorder.captured
    }
}
