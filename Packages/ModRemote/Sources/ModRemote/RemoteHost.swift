import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Network
import TUCore

/// Host side: listens on this Mac's Tailscale address only, accepts tailnet peers only, one session at a time.
@MainActor
@Observable
final class RemoteHost {
    enum State: Equatable {
        case stopped
        /// No 100.x address: Tailscale is off or disconnected. Retried by the module.
        case waitingForTailscale
        case listening(address: String)
        case failed(String)
    }

    private(set) var state = State.stopped
    private(set) var session: HostSession?
    /// Shown for the session, e.g. "taegyu-CGQM"; falls back to the address.
    private(set) var sessionPeerName: String?
    /// Why the last session ended, until the next one starts.
    private(set) var lastSessionEnd: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let log: ModuleLog
    @ObservationIgnored var peerName: (String) -> String? = { _ in nil }

    init(log: ModuleLog) {
        self.log = log
    }

    var isListening: Bool {
        if case .listening = state { true } else { false }
    }

    func start() {
        guard listener == nil else { return }
        guard let address = Tailnet.localAddress() else {
            state = .waitingForTailscale
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: Tailnet.port)!)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            state = .failed("리스너를 만들 수 없습니다: \(error.localizedDescription)")
            return
        }
        listener.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated { self?.listenerChanged(newState, address: address) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        endSession(reason: "호스트가 원격 접속을 껐습니다")
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    /// Ends the current session from the host side (menu, idle timeout, module stop).
    func endSession(reason: String) {
        session?.end(reason: reason)
    }

    private func listenerChanged(_ newState: NWListener.State, address: String) {
        switch newState {
        case .ready:
            state = .listening(address: address)
            log.logger.info("listening on \(address, privacy: .public):\(Tailnet.port, privacy: .public)")
        case .failed(let error):
            log.logger.error("listener failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
            state = .failed("리스너 오류: \(error.localizedDescription)")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let remote = Self.remoteIPv4(connection.endpoint), Tailnet.isTailnetIPv4(remote) else {
            log.logger.info("rejected non-tailnet connection from \(String(describing: connection.endpoint), privacy: .public)")
            connection.cancel()
            return
        }
        guard session == nil else {
            HostSession.reject(connection, reason: "다른 기기가 이미 연결되어 있습니다")
            return
        }
        log.logger.info("session from \(remote, privacy: .public)")
        let session = HostSession(connection: connection, log: log)
        session.onEnd = { [weak self, weak session] reason in
            guard let self, let session, self.session === session else { return }
            self.session = nil
            self.sessionPeerName = nil
            self.lastSessionEnd = reason
        }
        self.session = session
        sessionPeerName = peerName(remote) ?? remote
        lastSessionEnd = nil
        session.start()
    }

    static func remoteIPv4(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return nil }
        return address.rawValue.map(String.init).joined(separator: ".")
    }
}

/// One connected client: video out, input in, display kept awake, ended by either side or by the idle timeout.
@MainActor
final class HostSession {
    static let idleTimeout: TimeInterval = 10 * 60
    /// The client pings every few seconds; silence this long means the link is gone.
    static let silenceTimeout: TimeInterval = 20
    static let helloTimeout: TimeInterval = 5

    var onEnd: ((String?) -> Void)?

    private let connection: NWConnection
    private let log: ModuleLog
    private let injector = InputInjector()
    private var deframer = MessageDeframer()
    private var streamer: ScreenStreamer?
    private var watchdog: Task<Void, Never>?
    private var lastReceived = Date()
    private var lastInput = Date()
    private var didHello = false
    private var isEnded = false
    private var wakeAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    init(connection: NWConnection, log: ModuleLog) {
        self.connection = connection
        self.log = log
    }

    /// Tells a second client why it cannot connect.
    static func reject(_ connection: NWConnection, reason: String) {
        connection.start(queue: .main)
        connection.send(content: RemoteMessage.bye(reason: reason).encoded(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let error): self?.end(reason: nil, detail: error.localizedDescription)
                case .cancelled: self?.end(reason: nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.checkTimers()
            }
        }
    }

    func end(reason: String?, detail: String? = nil) {
        guard !isEnded else { return }
        isEnded = true
        log.logger.info("session ended: \(reason ?? detail ?? "client left", privacy: .public)")
        watchdog?.cancel()
        streamer?.stop()
        streamer = nil
        injector.releaseAll()
        releaseAssertions()
        if let reason {
            let connection = connection
            connection.send(content: RemoteMessage.bye(reason: reason).encoded(), completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
        onEnd?(reason ?? detail)
        onEnd = nil
    }

    private func checkTimers() {
        let now = Date()
        if !didHello, now.timeIntervalSince(lastReceived) > Self.helloTimeout {
            end(reason: "세션 시작 메시지가 없습니다")
        } else if now.timeIntervalSince(lastReceived) > Self.silenceTimeout {
            end(reason: nil, detail: "클라이언트 응답 없음")
        } else if now.timeIntervalSince(lastInput) > Self.idleTimeout {
            end(reason: "10분 동안 입력이 없어 연결을 끊었습니다")
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isEnded else { return }
                if let data, !data.isEmpty {
                    do {
                        for message in try self.deframer.append(data) {
                            self.handle(message)
                        }
                    } catch {
                        self.end(reason: "잘못된 데이터: \(error)")
                        return
                    }
                }
                if isComplete || error != nil {
                    self.end(reason: nil, detail: error?.localizedDescription)
                } else if !self.isEnded {
                    self.receive()
                }
            }
        }
    }

    private func handle(_ message: RemoteMessage) {
        lastReceived = Date()
        switch message {
        case .hello(let version, let maxWidth):
            guard !didHello else { return }
            didHello = true
            guard version == RemoteMessage.version else {
                end(reason: "T-Utilities 버전이 서로 다릅니다. 두 Mac을 같은 버전으로 업데이트하세요")
                return
            }
            beginStreaming(maxWidth: Int(maxWidth))
        case .input(let input):
            lastInput = Date()
            injector.apply(input)
        case .setMaxWidth(let width):
            streamer?.setMaxWidth(Int(width))
        case .requestKeyFrame:
            streamer?.requestKeyFrame()
        case .ping:
            connection.send(content: RemoteMessage.pong.encoded(), completion: .contentProcessed { _ in })
        case .bye:
            end(reason: nil, detail: "클라이언트가 연결을 끊었습니다")
        case .pong, .videoConfig, .videoFrame:
            break
        }
    }

    private func beginStreaming(maxWidth: Int) {
        guard Permission.screenRecording.isGranted else {
            end(reason: "호스트 Mac에 화면 기록 권한이 없습니다")
            return
        }
        // Without Accessibility the picture still works; clicks and keys are silently dropped by macOS.
        if !Permission.accessibility.isGranted {
            log.logger.error("accessibility missing: input will be ignored")
        }
        holdDisplayAwake()
        let connection = connection
        let streamer = ScreenStreamer(
            send: { message, completion in
                connection.send(content: message.encoded(), completion: .contentProcessed { _ in completion() })
            },
            onFailure: { [weak self] message in
                Task { @MainActor in self?.end(reason: message) }
            }
        )
        self.streamer = streamer
        Task { [weak self] in
            do {
                try await streamer.start(maxWidth: maxWidth)
            } catch {
                self?.end(reason: "화면 캡처를 시작할 수 없습니다: \(error.localizedDescription)")
            }
        }
    }

    /// Wakes the display (it may be asleep or at the lock screen) and keeps it on for the session. Owned here, not
    /// by Awake: modules never depend on each other.
    private func holdDisplayAwake() {
        IOPMAssertionDeclareUserActivity("T-Utilities Remote session" as CFString, kIOPMUserActiveLocal, &wakeAssertion)
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "T-Utilities Remote session" as CFString, &displayAssertion
        )
    }

    private func releaseAssertions() {
        if wakeAssertion != 0 { IOPMAssertionRelease(wakeAssertion) }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion) }
        wakeAssertion = 0
        displayAssertion = 0
    }
}
