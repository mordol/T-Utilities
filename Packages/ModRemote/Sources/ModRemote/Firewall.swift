import Foundation

/// The macOS Application Firewall asks once whether T-Utilities may accept incoming connections. A "Deny" there
/// makes the host unreachable with no other sign, so the host settings show this state.
enum Firewall {
    enum State: Equatable, Sendable {
        case off
        /// On, and T-Utilities may accept connections.
        case allowed
        /// On, and T-Utilities is blocked (the user clicked Deny).
        case blocked
        /// On, and macOS has not asked yet (it will on the first incoming connection).
        case notAsked
    }

    static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    /// Reads the state without admin rights. Nil if the tool is missing or its output is unknown.
    static func state(appPath: String = Bundle.main.bundlePath) async -> State? {
        await Task.detached(priority: .utility) {
            guard let global = run(["--getglobalstate"]) else { return nil }
            return parse(global: global, app: run(["--getappblocked", appPath]) ?? "")
        }.value
    }

    static func parse(global: String, app: String) -> State? {
        if global.contains("disabled") { return .off }
        guard global.contains("enabled") else { return nil }
        if app.contains("is blocked") { return .blocked }
        if app.contains("is permitted") { return .allowed }
        return .notAsked
    }

    private static func run(_ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
