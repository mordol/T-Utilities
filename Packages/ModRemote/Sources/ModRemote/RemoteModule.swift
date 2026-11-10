import AppKit
import SwiftUI
import TUCore
import TUUI

/// Mac ↔ Mac remote control over Tailscale. Every Mac is both host (shares its screen while "원격 접속 허용" is on)
/// and client (opens a viewer window). Tailscale is the security boundary: the host listens only on its 100.x
/// address and only accepts tailnet peers.
@MainActor
@Observable
public final class RemoteModule: TUModule {
    public static let descriptor = ModuleDescriptor(
        id: "remote",
        displayName: "Remote",
        symbol: "display.2",
        requiredPermissions: [.screenRecording, .accessibility],
        hasPopoverSection: true,
        enabledByDefault: false
    )

    static let defaultMaxWidth = 1920
    /// While hosting is on: how often a missing listener (no Tailscale yet, address changed) is retried.
    static let listenerCheckInterval: Duration = .seconds(15)

    @ObservationIgnored private let settings: ModuleSettings
    @ObservationIgnored private let popover: PopoverControl
    @ObservationIgnored private let log: ModuleLog
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var viewer: ViewerWindowController?
    private(set) var host: RemoteHost?
    /// Last `tailscale status`; nil when the CLI is missing or Tailscale is not running.
    private(set) var tailnet: Tailnet.Status?
    private(set) var isRefreshing = false
    /// macOS Application Firewall, as it applies to this app; read when hosting is turned on and in Settings.
    private(set) var firewall: Firewall.State?

    /// Host side. Off by default: nobody can connect until the user turns it on.
    var isListening: Bool {
        didSet {
            settings.set(isListening, for: "listening")
            updateListener()
        }
    }
    var isExpanded: Bool {
        didSet {
            settings.set(isExpanded, for: "expanded")
            if isExpanded { refreshPeers() }
        }
    }
    /// Stream width limit asked of hosts; the viewer can change it during a session.
    var maxWidth: Int {
        didSet { settings.set(maxWidth, for: "maxWidth") }
    }
    /// MagicDNS names or 100.x addresses added by hand.
    var manualPeers: [String] {
        didSet { settings.set(manualPeers, for: "manualPeers") }
    }

    public init(context: ModuleContext) {
        settings = context.settings
        popover = context.popover
        log = context.log
        isListening = context.settings.value("listening", default: false)
        isExpanded = context.settings.value("expanded", default: false)
        maxWidth = context.settings.value("maxWidth", default: Self.defaultMaxWidth)
        manualPeers = context.settings.value("manualPeers", default: [String]())
    }

    public func start() async throws {
        let host = RemoteHost(log: log)
        host.peerName = { [weak self] address in
            self?.tailnet?.peers.first { $0.address == address }?.name
        }
        self.host = host
        updateListener()
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.listenerCheckInterval)
                self?.checkListener()
            }
        }
        refreshPeers()
    }

    public func stop() async {
        maintenance?.cancel()
        maintenance = nil
        viewer?.close()
        viewer = nil
        host?.stop()
        host = nil
        tailnet = nil
    }

    // MARK: - Host

    private func updateListener() {
        guard let host else { return }
        if isListening {
            host.start()
            refreshFirewall()
        } else {
            host.stop()
        }
    }

    /// Starts the listener once Tailscale is up, and rebinds when this Mac's Tailscale address changes.
    private func checkListener() {
        guard isListening, let host else { return }
        if case .listening(let address) = host.state, address == Tailnet.localAddress() { return }
        if host.session != nil { return }
        host.stop()
        host.start()
    }

    func refreshFirewall() {
        Task { [weak self] in
            let state = await Firewall.state()
            self?.firewall = state
        }
    }

    func endHostSession() {
        host?.endSession(reason: "호스트에서 연결을 끊었습니다")
    }

    // MARK: - Client

    var peers: [RemotePeer] {
        let found = tailnet?.peers ?? []
        let manual = manualPeers
            .filter { address in !found.contains { $0.address == address } }
            .map { RemotePeer(address: $0, name: $0, isOnline: true, isManual: true) }
        return found + manual
    }

    func refreshPeers() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            let status = await Tailnet.status()
            guard let self else { return }
            tailnet = status
            isRefreshing = false
        }
    }

    func connect(to peer: RemotePeer) {
        popover.close()
        viewer?.close()
        let viewer = ViewerWindowController(peer: peer, maxWidth: maxWidth)
        viewer.onClose = { [weak self, weak viewer] in
            guard let self, self.viewer === viewer else { return }
            self.viewer = nil
        }
        viewer.onMaxWidthChange = { [weak self] width in self?.maxWidth = width }
        self.viewer = viewer
        viewer.show()
    }

    func addManualPeer(_ text: String) {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !manualPeers.contains(address) else { return }
        manualPeers.append(address)
    }

    // MARK: - TUModule

    public var status: ModuleStatus {
        guard isListening else { return .running }
        if !Permission.screenRecording.isGranted { return .needsPermission(.screenRecording) }
        if !Permission.accessibility.isGranted { return .needsPermission(.accessibility) }
        switch host?.state {
        case .waitingForTailscale: return .degraded("Tailscale 연결 필요")
        case .failed(let message): return .error(message)
        default: return .running
        }
    }

    public var statusItemText: String? {
        host?.session != nil ? "원격" : nil
    }

    public func popoverWillShow() {
        if isExpanded { refreshPeers() }
    }

    public func makeQuickMenuItems() -> [NSMenuItem] {
        guard let name = host?.sessionPeerName else { return [] }
        return [ClosureMenuItem("원격 세션 끊기 (\(name))") { [weak self] in self?.endHostSession() }]
    }

    public func makePopoverSection() -> AnyView? {
        AnyView(RemoteSectionView(module: self))
    }

    public func makeSettingsView() -> AnyView {
        AnyView(RemoteSettingsView(module: self))
    }
}

// MARK: - Popover

private struct RemoteSectionView: View {
    @Bindable var module: RemoteModule

    var body: some View {
        VStack(spacing: 0) {
            SectionRow(symbol: RemoteModule.descriptor.symbol, title: "Remote") {
                HStack(spacing: 8) {
                    if module.host?.session != nil {
                        Text("연결됨").foregroundStyle(.green)
                    }
                    Toggle("원격 접속 허용", isOn: $module.isListening)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help("이 Mac에 원격 접속 허용 (Tailscale 기기만)")
                    Image(systemName: module.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .onTapGesture { module.isExpanded.toggle() }
            .help("접속할 Mac 목록")

            if module.isExpanded {
                RemotePeerList(module: module)
            }
        }
    }
}

private struct RemotePeerList: View {
    let module: RemoteModule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = module.host?.sessionPeerName {
                HStack {
                    Label("\(name)에서 이 Mac에 접속 중", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("끊기", action: module.endHostSession).controlSize(.small)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            let peers = module.peers
            if peers.isEmpty {
                Text(module.isRefreshing ? "Mac을 찾는 중…" : emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            ForEach(peers) { peer in
                Button { module.connect(to: peer) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(peer.name).lineLimit(1)
                        Spacer(minLength: 8)
                        if !peer.isOnline {
                            Text("오프라인").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .opacity(peer.isOnline ? 1 : 0.5)
                    .padding(.leading, 30)
                    .padding(.trailing, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(peer.address)에 접속")
            }
        }
        .padding(.bottom, 4)
    }

    private var emptyMessage: String {
        module.tailnet == nil
            ? "Tailscale을 찾을 수 없습니다. Tailscale을 실행하거나 설정에서 Mac을 직접 추가하세요."
            : "접속할 수 있는 Mac이 없습니다"
    }
}

// MARK: - Settings

private struct RemoteSettingsView: View {
    @Bindable var module: RemoteModule
    @State private var newPeer = ""

    var body: some View {
        Form {
            Section {
                Toggle("이 Mac에 원격 접속 허용", isOn: $module.isListening)
                LabeledContent("상태") { hostState }
                if let name = module.host?.sessionPeerName {
                    LabeledContent("접속 중") {
                        HStack {
                            Text(name)
                            Button("끊기", action: module.endHostSession)
                        }
                    }
                } else if let reason = module.host?.lastSessionEnd {
                    LabeledContent("마지막 세션") { Text(reason).foregroundStyle(.secondary) }
                }
                FirewallRow(state: module.firewall)
                PermissionRow(permission: .screenRecording, purpose: "화면 보내기")
                PermissionRow(permission: .accessibility, purpose: "마우스·키보드 받기")
            } header: {
                Text("호스트 (이 Mac)")
            } footer: {
                Text("켜 두면 같은 Tailscale 네트워크(tailnet)의 기기가 승인 없이 이 Mac을 보고 조작할 수 있습니다. Tailscale 주소(100.x)에서만 기다리며, 동시 접속은 1개, 10분 동안 입력이 없으면 연결을 끊습니다. 잠긴 Mac은 잠금 화면이 보이고 암호를 입력해 열 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("접속 (다른 Mac 보기)") {
                Picker("전송 해상도", selection: $module.maxWidth) {
                    ForEach(ViewerWindowController.widthChoices, id: \.self) { width in
                        Text("최대 폭 \(width)px").tag(width)
                    }
                }
                Text("접속 중에도 창 제목 표시줄에서 바꿀 수 있습니다. 30fps가 상한입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(module.manualPeers, id: \.self) { address in
                    HStack {
                        Text(address)
                        Spacer()
                        Button(role: .destructive) {
                            module.manualPeers.removeAll { $0 == address }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("MagicDNS 이름 또는 100.x 주소", text: $newPeer)
                        .onSubmit(add)
                    Button("추가", action: add).disabled(newPeer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("직접 추가한 Mac")
            } footer: {
                Text("Tailscale에 로그인된 macOS 기기는 팝오버 목록에 자동으로 나옵니다. 목록에 없는 Mac만 여기 추가하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { module.refreshFirewall() }
    }

    @ViewBuilder
    private var hostState: some View {
        switch module.host?.state {
        case .listening(let address):
            Text("\(address):\(String(Tailnet.port))에서 대기 중").foregroundStyle(.green)
        case .waitingForTailscale:
            Text("Tailscale 연결 필요").foregroundStyle(.orange)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .stopped, nil:
            Text("꺼짐").foregroundStyle(.secondary)
        }
    }

    private func add() {
        module.addManualPeer(newPeer)
        newPeer = ""
    }
}

private struct FirewallRow: View {
    let state: Firewall.State?

    var body: some View {
        switch state {
        case .notAsked:
            hint("macOS 방화벽이 켜져 있습니다. 처음 접속받을 때 나오는 창에서 '허용'을 누르세요.", color: .orange)
        case .blocked:
            hint("macOS 방화벽이 T-Utilities의 연결을 막고 있습니다. 시스템 설정 → 네트워크 → 방화벽 → 옵션에서 T-Utilities를 '들어오는 연결 허용'으로 바꾸세요.", color: .red)
        case .allowed:
            LabeledContent("macOS 방화벽") {
                Label("허용됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .off, nil:
            EmptyView()
        }
    }

    private func hint(_ text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.shield").foregroundStyle(color)
            Button("방화벽 설정 열기") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")!)
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let purpose: String

    var body: some View {
        LabeledContent("\(permission.displayName) (\(purpose))") {
            if permission.isGranted {
                Label("허용됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("허용하기…") { permission.request() }
            }
        }
    }
}
