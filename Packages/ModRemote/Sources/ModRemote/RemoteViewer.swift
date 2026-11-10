import AppKit
import AVFoundation
import CoreMedia
import Network
import SwiftUI

/// Client side: one window showing a host's screen. Closing the window ends the session.
@MainActor
@Observable
final class ViewerModel {
    enum Phase: Equatable {
        case connecting
        case streaming
        case ended(String)
    }

    var phase = Phase.connecting
    var maxWidth: Int
    let peer: RemotePeer

    init(peer: RemotePeer, maxWidth: Int) {
        self.peer = peer
        self.maxWidth = maxWidth
    }
}

@MainActor
final class ViewerWindowController: NSObject, NSWindowDelegate {
    static let widthChoices = [1280, 1600, 1920, 2560]
    static let pingInterval: Duration = .seconds(5)

    let model: ViewerModel
    /// Called once the window has closed; the module drops its reference.
    var onClose: (() -> Void)?
    /// Called when the user picks another stream width (remembered for the next session).
    var onMaxWidthChange: ((Int) -> Void)?

    private let window: NSWindow
    private let videoView = VideoView()
    private var connection: NWConnection?
    private var deframer = MessageDeframer()
    private var format: CMVideoFormatDescription?
    private var videoSize: CGSize?
    private var waitsForKeyFrame = true
    private var pinger: Task<Void, Never>?

    init(peer: RemotePeer, maxWidth: Int) {
        model = ViewerModel(peer: peer, maxWidth: maxWidth)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init()
        window.title = "\(peer.name) — Remote"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true
        let container = NSView()
        videoView.frame = container.bounds
        videoView.autoresizingMask = [.width, .height]
        container.addSubview(videoView)
        let overlay = PassthroughHostingView(rootView: ViewerOverlay(model: model))
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        window.contentView = container
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = NSHostingView(rootView: ViewerToolbar(model: model, onWidth: { [weak self] in self?.changeMaxWidth($0) }))
        accessory.view.frame.size = accessory.view.fittingSize
        window.addTitlebarAccessoryViewController(accessory)
        videoView.onInput = { [weak self] in self?.send(.input($0)) }
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        connect()
    }

    func close() {
        window.close()
    }

    // MARK: - Connection

    private func connect() {
        let port = NWEndpoint.Port(rawValue: Tailnet.port)!
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
        }
        let connection = NWConnection(host: NWEndpoint.Host(model.peer.address), port: port, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(state) }
        }
        self.connection = connection
        connection.start(queue: .main)
        receive()
    }

    private func connectionChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(.hello(version: RemoteMessage.version, maxWidth: UInt16(model.maxWidth)))
            pinger = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pingInterval)
                    self?.send(.ping)
                }
            }
        case .waiting(let error):
            finish("연결할 수 없습니다: \(error.localizedDescription)\n상대 Mac에서 Remote의 원격 접속 허용이 켜져 있는지 확인하세요.")
        case .failed(let error):
            finish("연결이 끊겼습니다: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.connection != nil else { return }
                if let data, !data.isEmpty {
                    do {
                        for message in try self.deframer.append(data) {
                            self.handle(message)
                        }
                    } catch {
                        self.finish("잘못된 데이터를 받았습니다")
                        return
                    }
                }
                if isComplete || error != nil {
                    self.finish(error.map { "연결이 끊겼습니다: \($0.localizedDescription)" } ?? "연결이 끊겼습니다")
                } else if self.connection != nil {
                    self.receive()
                }
            }
        }
    }

    private func send(_ message: RemoteMessage) {
        connection?.send(content: message.encoded(), completion: .contentProcessed { _ in })
    }

    /// Stops the session but keeps the window, so the user can read why.
    private func finish(_ message: String) {
        guard let connection else { return }
        pinger?.cancel()
        connection.cancel()
        self.connection = nil
        videoView.releaseKeys()
        if case .ended = model.phase { return }
        model.phase = .ended(message)
    }

    private func changeMaxWidth(_ width: Int) {
        guard width != model.maxWidth else { return }
        model.maxWidth = width
        onMaxWidthChange?(width)
        waitsForKeyFrame = true
        send(.setMaxWidth(UInt16(width)))
    }

    // MARK: - Video

    private func handle(_ message: RemoteMessage) {
        switch message {
        case .videoConfig(let width, let height, let parameterSets):
            format = Self.makeFormat(parameterSets)
            waitsForKeyFrame = true
            resize(to: CGSize(width: Int(width), height: Int(height)))
        case .videoFrame(let isKeyFrame, let data):
            guard let format, !(waitsForKeyFrame && !isKeyFrame), let sample = Self.makeSample(data, format: format) else { return }
            waitsForKeyFrame = false
            let renderer = videoView.displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
                waitsForKeyFrame = true
                send(.requestKeyFrame)
                return
            }
            renderer.enqueue(sample)
            if model.phase != .streaming { model.phase = .streaming }
        case .bye(let reason):
            finish(reason)
        case .pong, .ping, .hello, .input, .setMaxWidth, .requestKeyFrame:
            break
        }
    }

    /// First picture: fit the window into the screen. Later: keep the width, follow the aspect ratio.
    private func resize(to size: CGSize) {
        videoView.videoSize = size
        window.contentAspectRatio = size
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let current = window.contentLayoutRect.size
        var width = videoSize == nil ? min(area.width * 0.85, area.height * 0.85 * size.width / size.height) : current.width
        width = min(width, area.width)
        let content = NSSize(width: width, height: width * size.height / size.width)
        videoSize = size
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        if window.frame.size != frame.size { window.setFrame(frame, display: true, animate: false) }
    }

    nonisolated static func makeFormat(_ parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let buffers = parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: nil, parameterSetCount: buffers.count, parameterSetPointers: buffers.map { UnsafePointer($0) },
            parameterSetSizes: parameterSets.map(\.count), nalUnitHeaderLength: 4, formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    nonisolated static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Keys held while switching away would otherwise stay down on the host.
        videoView.releaseKeys()
    }

    func windowWillClose(_ notification: Notification) {
        if connection != nil {
            send(.bye(reason: ""))
            let connection = connection
            self.connection = nil
            pinger?.cancel()
            // Give the bye a moment to leave before the socket closes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { connection?.cancel() }
        }
        videoView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        onClose?()
        onClose = nil
    }
}

private struct ViewerOverlay: View {
    let model: ViewerModel

    var body: some View {
        switch model.phase {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView()
                Text("\(model.peer.name)에 연결하는 중…").foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .streaming:
            Color.clear.allowsHitTesting(false)
        case .ended(let message):
            VStack(spacing: 8) {
                Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle)
                Text(message).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(20)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ViewerToolbar: View {
    let model: ViewerModel
    let onWidth: @MainActor @Sendable (Int) -> Void

    var body: some View {
        Picker("해상도", selection: Binding(get: { model.maxWidth }, set: onWidth)) {
            ForEach(ViewerWindowController.widthChoices, id: \.self) { width in
                Text("최대 폭 \(width)px").tag(width)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("전송 해상도. 낮추면 빠르고 가벼워집니다.")
        .padding(.trailing, 8)
    }
}

/// Status text over the video that never takes the mouse away from it.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shows the stream and turns local mouse/keyboard events into normalized `RemoteInput`.
private final class VideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var videoSize: CGSize?
    var onInput: ((RemoteInput) -> Void)?
    private var keysDown: Set<UInt16> = []
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Point in the view → 0…1 of the picture (top-left origin), ignoring the letterbox bars.
    private func normalized(_ event: NSEvent) -> (Float, Float) {
        let point = convert(event.locationInWindow, from: nil)
        let picture = videoSize.map { AVMakeRect(aspectRatio: $0, insideRect: bounds) } ?? bounds
        guard picture.width > 0, picture.height > 0 else { return (0, 0) }
        let x = (point.x - picture.minX) / picture.width
        let y = isFlipped ? (point.y - picture.minY) / picture.height : 1 - (point.y - picture.minY) / picture.height
        return (Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1)))
    }

    private func move(_ event: NSEvent) {
        let (x, y) = normalized(event)
        onInput?(.mouseMove(x: x, y: y))
    }

    private func button(_ event: NSEvent, _ button: MouseButton, isDown: Bool) {
        let (x, y) = normalized(event)
        let clicks = UInt8(clamping: event.clickCount)
        onInput?(isDown ? .mouseDown(button: button, x: x, y: y, clickCount: clicks) : .mouseUp(button: button, x: x, y: y, clickCount: clicks))
    }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }
    override func mouseDown(with event: NSEvent) { button(event, .left, isDown: true) }
    override func mouseUp(with event: NSEvent) { button(event, .left, isDown: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, .right, isDown: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, .right, isDown: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, .other, isDown: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, .other, isDown: false) }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        onInput?(.scroll(
            dx: Int32(clamping: Int(event.scrollingDeltaX.rounded())),
            dy: Int32(clamping: Int(event.scrollingDeltaY.rounded())),
            isPrecise: precise
        ))
    }

    private static func flags(_ event: NSEvent) -> UInt64 {
        UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    override func keyDown(with event: NSEvent) {
        keysDown.insert(event.keyCode)
        onInput?(.key(code: event.keyCode, isDown: true, isRepeat: event.isARepeat, flags: Self.flags(event)))
    }

    override func keyUp(with event: NSEvent) {
        keysDown.remove(event.keyCode)
        onInput?(.key(code: event.keyCode, isDown: false, isRepeat: false, flags: Self.flags(event)))
    }

    /// ⌘-shortcuts go to the host too, not to this app's (non-existent) menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard let flag = Self.modifierFlag(for: event.keyCode) else { return }
        let isDown = event.modifierFlags.contains(flag)
        if isDown { keysDown.insert(event.keyCode) } else { keysDown.remove(event.keyCode) }
        onInput?(.key(code: event.keyCode, isDown: isDown, isRepeat: false, flags: Self.flags(event)))
    }

    func releaseKeys() {
        for code in keysDown {
            onInput?(.key(code: code, isDown: false, isRepeat: false, flags: 0))
        }
        keysDown = []
    }

    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x37, 0x36: .command
        case 0x38, 0x3C: .shift
        case 0x3A, 0x3D: .option
        case 0x3B, 0x3E: .control
        case 0x39: .capsLock
        case 0x3F: .function
        default: nil
        }
    }
}
