import Darwin
import Foundation

/// A Mac on the tailnet that can be connected to.
struct RemotePeer: Identifiable, Hashable, Sendable {
    /// What the client connects to: a Tailscale IPv4 address or a MagicDNS name typed by the user.
    let address: String
    let name: String
    let isOnline: Bool
    /// Added by hand in Settings rather than found in `tailscale status`.
    let isManual: Bool

    var id: String { address }
}

/// Tailscale is the whole security boundary (Docs: ModRemote): the host listens only on this Mac's Tailscale
/// address and accepts only tailnet (CGNAT 100.64.0.0/10) peers.
enum Tailnet {
    static let port: UInt16 = 48620

    /// 100.64.0.0/10.
    static func isTailnetIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && parts[1] & 0xC0 == 64
    }

    /// This Mac's Tailscale IPv4 address, read from the network interfaces (works without the CLI).
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isTailnetIPv4(text) { return text }
        }
        return nil
    }

    // MARK: - tailscale status

    struct Status: Equatable, Sendable {
        var isRunning: Bool
        var selfAddress: String?
        /// Other macOS devices, online first.
        var peers: [RemotePeer]
    }

    static let cliPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// Runs `tailscale status --json` off the main thread. Nil when the CLI is missing or fails.
    static func status() async -> Status? {
        guard let path = cliPaths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["status", "--json"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parseStatus(data)
        }.value
    }

    static func parseStatus(_ data: Data) -> Status? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let me = root["Self"] as? [String: Any]
        let peers = (root["Peer"] as? [String: [String: Any]] ?? [:]).values.compactMap { peer -> RemotePeer? in
            guard peer["OS"] as? String == "macOS",
                  let address = (peer["TailscaleIPs"] as? [String])?.first(where: isTailnetIPv4) else { return nil }
            let dnsName = (peer["DNSName"] as? String).flatMap { $0.split(separator: ".").first.map(String.init) }
            let name = (peer["HostName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dnsName ?? address
            return RemotePeer(address: address, name: name, isOnline: peer["Online"] as? Bool ?? false, isManual: false)
        }
        return Status(
            isRunning: root["BackendState"] as? String == "Running",
            selfAddress: (me?["TailscaleIPs"] as? [String])?.first(where: isTailnetIPv4),
            peers: peers.sorted { ($0.isOnline ? 0 : 1, $0.name.lowercased()) < ($1.isOnline ? 0 : 1, $1.name.lowercased()) }
        )
    }
}
