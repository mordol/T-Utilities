import Foundation
import Security

/// API keys live in the login Keychain, never in the settings plist.
enum TranslationKeychain {
    private static let service = "com.taegyu.tutilities.translation"

    static func key(for engine: TranslationEngine) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: engine.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Empty removes the key.
    @discardableResult
    static func setKey(_ key: String, for engine: TranslationEngine) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: engine.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

struct TranslationRequest: Sendable {
    let engine: TranslationEngine
    let model: String
    let system: String
    let user: String
}

enum TranslationRunner {
    static let timeout: Duration = .seconds(120)

    /// Translates `request`; `onPartial` receives the text so far while a CLI streams. Cancelling the task stops
    /// the request or terminates the CLI.
    static func run(_ request: TranslationRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        if request.engine.isCLI {
            return try await runCLI(request, onPartial: onPartial)
        }
        guard let apiKey = TranslationKeychain.key(for: request.engine) else {
            throw TranslationError("\(request.engine.title) 키가 없습니다. 설정 → Clipboard → 번역에서 입력하세요.")
        }
        let urlRequest = try TranslationAPI.request(
            engine: request.engine, model: request.model, apiKey: apiKey, system: request.system, user: request.user
        )
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        return try TranslationAPI.parse(engine: request.engine, status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    private static func runCLI(_ request: TranslationRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let executable = TranslationCLI.executable(for: request.engine) else {
            throw TranslationError("""
                \(request.engine.executableName ?? "CLI")을(를) 찾지 못했습니다. 설치한 뒤 터미널에서 한 번 로그인하세요. \
                (찾는 위치: \(TranslationCLI.searchDirectories().joined(separator: ", ")))
                """)
        }
        // Empty scratch directory as cwd, so there is nothing to read even if a tool slipped through.
        let workDirectory = FileManager.default.temporaryDirectory.appending(path: "T-Utilities-translate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        if request.engine == .cursorCLI {
            let config = workDirectory.appending(path: ".cursor")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try Data(TranslationCLI.cursorPermissions.utf8).write(to: config.appending(path: "cli.json"))
        }

        let invocation = TranslationCLI.invocation(engine: request.engine, model: request.model, system: request.system, user: request.user)
        let process = Process()
        process.executableURL = executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = workDirectory
        // Inherit HOME/USER (the CLIs' logins depend on them) and add the usual tool locations to PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (TranslationCLI.searchDirectories() + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        let started = ContinuousClock.now
        try process.run()

        nonisolated(unsafe) let running = process
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            running.terminate()
        }
        defer { watchdog.cancel() }
        // stdin must be closed right after writing, or codex waits for more input.
        let input = stdin.fileHandleForWriting
        if let text = invocation.stdin { try? input.write(contentsOf: Data(text.utf8)) }
        try? input.close()
        // Drain stderr concurrently so a chatty CLI can't block on a full pipe.
        let errorOutput = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }

        var text = ""
        var failure: String?
        try await withTaskCancellationHandler {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                guard let event = TranslationCLI.parse(engine: request.engine, line: line) else { continue }
                if case .failure(let message) = event { failure = message; continue }
                text = TranslationCLI.apply(event, to: text, engine: request.engine)
                let partial = text
                await onPartial(partial)
            }
        } onCancel: {
            running.terminate()
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        let errorText = String(data: await errorOutput.value, encoding: .utf8) ?? ""

        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure { throw TranslationError(failure) }
        if process.terminationReason == .uncaughtSignal, ContinuousClock.now - started >= timeout {
            throw TranslationError("\(request.engine.title) 응답이 \(Int(timeout.components.seconds))초 안에 오지 않았습니다")
        }
        if process.terminationStatus != 0 || result.isEmpty {
            let detail = errorText.trimmingCharacters(in: .whitespacesAndNewlines).suffix(500)
            throw TranslationError("\(request.engine.title) 실행 실패 (\(process.terminationStatus)): \(detail.isEmpty ? "출력 없음" : String(detail))")
        }
        return result
    }
}
