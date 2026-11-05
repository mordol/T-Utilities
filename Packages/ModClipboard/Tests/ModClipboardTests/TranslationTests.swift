import Foundation
import Testing
@testable import ModClipboard

struct TranslationPromptTests {
    @Test func mutualTranslationPicksTheOtherLanguage() {
        #expect(TranslationPrompt.target(for: "안녕하세요, 오늘 회의는 세 시에 시작합니다.", primary: .korean, secondary: .english) == .english)
        #expect(TranslationPrompt.target(for: "The meeting starts at three o'clock today.", primary: .korean, secondary: .english) == .korean)
        // A third language goes to the primary language.
        #expect(TranslationPrompt.target(for: "今日の会議は三時に始まります。", primary: .korean, secondary: .english) == .korean)
    }

    @Test func guidelinesAreAppendedOnlyWhenPresent() {
        #expect(!TranslationPrompt.system(target: .korean, guidelines: "  \n").contains("guidelines"))
        let prompt = TranslationPrompt.system(target: .english, guidelines: "존댓말")
        #expect(prompt.contains("into English") && prompt.hasSuffix("존댓말"))
    }
}

struct TranslationAPITests {
    @Test func anthropicRequestShape() throws {
        let request = try TranslationAPI.request(engine: .claudeAPI, model: "claude-opus-5-5", apiKey: "k", system: "S", user: "U")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["system"] as? String == "S")
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
    }

    @Test func parsesEachProvider() throws {
        let claude = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":" 안녕 "}],"stop_reason":"end_turn"}"#
        #expect(try TranslationAPI.parse(engine: .claudeAPI, status: 200, data: Data(claude.utf8)) == "안녕")
        let openAI = #"{"choices":[{"message":{"role":"assistant","content":"Hello"}}]}"#
        #expect(try TranslationAPI.parse(engine: .openAIAPI, status: 200, data: Data(openAI.utf8)) == "Hello")
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"Bon"},{"text":"jour"}]}}]}"#
        #expect(try TranslationAPI.parse(engine: .geminiAPI, status: 200, data: Data(gemini.utf8)) == "Bonjour")
    }

    @Test func reportsProviderErrorsAndRefusals() {
        let error = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        #expect(throws: TranslationError("Claude API 오류 (401): invalid x-api-key")) {
            try TranslationAPI.parse(engine: .claudeAPI, status: 401, data: Data(error.utf8))
        }
        let refusal = #"{"content":[],"stop_reason":"refusal"}"#
        #expect(throws: TranslationError.self) {
            try TranslationAPI.parse(engine: .claudeAPI, status: 200, data: Data(refusal.utf8))
        }
    }
}

struct TranslationCLITests {
    @Test func claudeInvocationDisablesToolsAndPassesPromptOnStdin() {
        let invocation = TranslationCLI.invocation(engine: .claudeCLI, model: "haiku", system: "S", user: "U")
        #expect(invocation.stdin == "U")
        #expect(invocation.arguments.contains("--no-session-persistence"))
        #expect(invocation.arguments.suffix(2) == ["--model", "haiku"])
        let tools = invocation.arguments.firstIndex(of: "--tools")!
        #expect(invocation.arguments[tools + 1] == "")
    }

    @Test func codexAndCursorInvocations() {
        let codex = TranslationCLI.invocation(engine: .codexCLI, model: "", system: "S", user: "U")
        #expect(codex.arguments.first == "exec" && codex.arguments.last == "-" && !codex.arguments.contains("--model"))
        #expect(codex.stdin == "S\n\nU")
        let cursor = TranslationCLI.invocation(engine: .cursorCLI, model: "", system: "S", user: "U")
        #expect(cursor.stdin == nil && cursor.arguments.last == "S\n\nU")
    }

    @Test func parsesClaudeStream() {
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"안"}}}"#
        #expect(TranslationCLI.parse(engine: .claudeCLI, line: delta) == .delta("안"))
        #expect(TranslationCLI.parse(engine: .claudeCLI, line: #"{"type":"system","subtype":"init"}"#) == nil)
        let failure = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
        #expect(TranslationCLI.parse(engine: .claudeCLI, line: failure) == .failure("Not logged in · Please run /login"))
        #expect(TranslationCLI.parse(engine: .claudeCLI, line: "not json") == nil)
    }

    @Test func parsesCodexMessagesAndNestedErrors() {
        let message = #"{"type":"item.completed","item":{"id":"1","type":"agent_message","text":"Hello"}}"#
        #expect(TranslationCLI.parse(engine: .codexCLI, line: message) == .full("Hello"))
        let nested = #"{"type":"turn.failed","error":{"message":"{\"error\":{\"message\":\"model not found\"}}"}}"#
        #expect(TranslationCLI.parse(engine: .codexCLI, line: nested) == .failure("model not found"))
    }

    @Test func cursorFinalRepeatIsNotAppendedTwice() {
        var text = ""
        for line in [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hel"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"lo"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#,
        ] {
            if let event = TranslationCLI.parse(engine: .cursorCLI, line: line) {
                text = TranslationCLI.apply(event, to: text, engine: .cursorCLI)
            }
        }
        #expect(text == "Hello")
    }
}
