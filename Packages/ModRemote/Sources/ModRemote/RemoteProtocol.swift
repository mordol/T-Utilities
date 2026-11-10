import Foundation

/// Wire format between two T-Utilities over Tailscale (plain TCP; WireGuard encrypts it).
///
/// Every message is `[UInt32 length][UInt8 type][payload]`, big-endian, where `length` counts the type byte and
/// the payload. Video is H.264 in AVCC form (4-byte NAL lengths), exactly as VideoToolbox emits it.
enum RemoteMessage: Equatable, Sendable {
    /// Client → host, first message. `maxWidth` is the stream width limit in pixels.
    case hello(version: UInt16, maxWidth: UInt16)
    /// Host → client before the first frame and after every size change.
    case videoConfig(width: UInt16, height: UInt16, parameterSets: [Data])
    case videoFrame(isKeyFrame: Bool, data: Data)
    case input(RemoteInput)
    /// Client → host: new stream width limit.
    case setMaxWidth(UInt16)
    /// Client → host after a decode failure: the next frame must be a key frame.
    case requestKeyFrame
    case ping
    case pong
    /// Either side, right before closing. Shown to the user.
    case bye(reason: String)

    static let version: UInt16 = 1
    /// Larger frames are treated as a broken stream.
    static let maxLength = 16 * 1024 * 1024
}

enum MouseButton: UInt8, Sendable {
    case left = 0
    case right = 1
    case other = 2
}

/// Pointer positions are normalized to the streamed display (0…1, origin top-left) so the two Macs never need to
/// agree on resolutions or scale factors.
enum RemoteInput: Equatable, Sendable {
    case mouseMove(x: Float, y: Float)
    case mouseDown(button: MouseButton, x: Float, y: Float, clickCount: UInt8)
    case mouseUp(button: MouseButton, x: Float, y: Float, clickCount: UInt8)
    /// Pixel deltas when `isPrecise` (trackpad), otherwise lines (wheel).
    case scroll(dx: Int32, dy: Int32, isPrecise: Bool)
    /// `flags` is NSEvent.ModifierFlags (device independent), which has the same bits as CGEventFlags.
    /// Modifier keys arrive as key down/up of their own key code.
    case key(code: UInt16, isDown: Bool, isRepeat: Bool, flags: UInt64)
}

private enum MessageType: UInt8 {
    case hello = 1, videoConfig, videoFrame, input, setMaxWidth, ping, pong, bye, requestKeyFrame
}

private enum InputType: UInt8 {
    case mouseMove = 1, mouseDown, mouseUp, scroll, key
}

struct RemoteProtocolError: Error, Equatable {
    let message: String
}

// MARK: - Encoding

extension RemoteMessage {
    func encoded() -> Data {
        var body = ByteWriter()
        switch self {
        case .hello(let version, let maxWidth):
            body.u8(MessageType.hello.rawValue); body.u16(version); body.u16(maxWidth)
        case .videoConfig(let width, let height, let parameterSets):
            body.u8(MessageType.videoConfig.rawValue); body.u16(width); body.u16(height)
            body.u8(UInt8(parameterSets.count))
            for set in parameterSets {
                body.u16(UInt16(set.count)); body.bytes(set)
            }
        case .videoFrame(let isKeyFrame, let data):
            body.u8(MessageType.videoFrame.rawValue); body.u8(isKeyFrame ? 1 : 0); body.bytes(data)
        case .input(let input):
            body.u8(MessageType.input.rawValue); input.write(to: &body)
        case .setMaxWidth(let width):
            body.u8(MessageType.setMaxWidth.rawValue); body.u16(width)
        case .requestKeyFrame:
            body.u8(MessageType.requestKeyFrame.rawValue)
        case .ping:
            body.u8(MessageType.ping.rawValue)
        case .pong:
            body.u8(MessageType.pong.rawValue)
        case .bye(let reason):
            body.u8(MessageType.bye.rawValue); body.bytes(Data(reason.utf8))
        }
        var framed = ByteWriter()
        framed.u32(UInt32(body.data.count))
        framed.bytes(body.data)
        return framed.data
    }
}

private extension RemoteInput {
    func write(to body: inout ByteWriter) {
        switch self {
        case .mouseMove(let x, let y):
            body.u8(InputType.mouseMove.rawValue); body.f32(x); body.f32(y)
        case .mouseDown(let button, let x, let y, let clickCount):
            body.u8(InputType.mouseDown.rawValue); body.u8(button.rawValue); body.f32(x); body.f32(y); body.u8(clickCount)
        case .mouseUp(let button, let x, let y, let clickCount):
            body.u8(InputType.mouseUp.rawValue); body.u8(button.rawValue); body.f32(x); body.f32(y); body.u8(clickCount)
        case .scroll(let dx, let dy, let isPrecise):
            body.u8(InputType.scroll.rawValue); body.u32(UInt32(bitPattern: dx)); body.u32(UInt32(bitPattern: dy))
            body.u8(isPrecise ? 1 : 0)
        case .key(let code, let isDown, let isRepeat, let flags):
            body.u8(InputType.key.rawValue); body.u16(code); body.u8((isDown ? 1 : 0) | (isRepeat ? 2 : 0)); body.u64(flags)
        }
    }
}

// MARK: - Decoding

/// Splits a TCP byte stream into messages. Feed it whatever arrives; it keeps partial messages for the next call.
struct MessageDeframer {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [RemoteMessage] {
        buffer.append(data)
        var messages: [RemoteMessage] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard length >= 1, length <= RemoteMessage.maxLength else {
                throw RemoteProtocolError(message: "잘못된 메시지 길이 \(length)")
            }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: start + 4 ..< start + 4 + length)
            buffer = buffer.subdata(in: start + 4 + length ..< buffer.endIndex)
            messages.append(try RemoteMessage(body: body))
        }
        return messages
    }
}

extension RemoteMessage {
    init(body: Data) throws {
        var reader = ByteReader(body)
        let rawType = try reader.u8()
        guard let type = MessageType(rawValue: rawType) else {
            throw RemoteProtocolError(message: "알 수 없는 메시지 \(rawType)")
        }
        switch type {
        case .hello:
            self = .hello(version: try reader.u16(), maxWidth: try reader.u16())
        case .videoConfig:
            let width = try reader.u16(), height = try reader.u16()
            let count = try reader.u8()
            var sets: [Data] = []
            for _ in 0 ..< count {
                sets.append(try reader.bytes(Int(try reader.u16())))
            }
            self = .videoConfig(width: width, height: height, parameterSets: sets)
        case .videoFrame:
            self = .videoFrame(isKeyFrame: try reader.u8() == 1, data: reader.rest())
        case .input:
            self = .input(try RemoteInput(reader: &reader))
        case .setMaxWidth:
            self = .setMaxWidth(try reader.u16())
        case .requestKeyFrame:
            self = .requestKeyFrame
        case .ping:
            self = .ping
        case .pong:
            self = .pong
        case .bye:
            self = .bye(reason: String(decoding: reader.rest(), as: UTF8.self))
        }
    }
}

private extension RemoteInput {
    init(reader: inout ByteReader) throws {
        let rawType = try reader.u8()
        switch InputType(rawValue: rawType) {
        case .mouseMove:
            self = .mouseMove(x: try reader.f32(), y: try reader.f32())
        case .mouseDown:
            let button = try MouseButton(raw: reader.u8())
            self = .mouseDown(button: button, x: try reader.f32(), y: try reader.f32(), clickCount: try reader.u8())
        case .mouseUp:
            let button = try MouseButton(raw: reader.u8())
            self = .mouseUp(button: button, x: try reader.f32(), y: try reader.f32(), clickCount: try reader.u8())
        case .scroll:
            let dx = Int32(bitPattern: try reader.u32()), dy = Int32(bitPattern: try reader.u32())
            self = .scroll(dx: dx, dy: dy, isPrecise: try reader.u8() == 1)
        case .key:
            let code = try reader.u16(), state = try reader.u8()
            self = .key(code: code, isDown: state & 1 != 0, isRepeat: state & 2 != 0, flags: try reader.u64())
        case nil:
            throw RemoteProtocolError(message: "알 수 없는 입력 \(rawType)")
        }
    }
}

private extension MouseButton {
    init(raw: UInt8) throws {
        guard let button = MouseButton(rawValue: raw) else { throw RemoteProtocolError(message: "알 수 없는 버튼 \(raw)") }
        self = button
    }
}

// MARK: - Bytes

private struct ByteWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ value: Float) { u32(value.bitPattern) }
    mutating func bytes(_ value: Data) { data.append(value) }
}

private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw RemoteProtocolError(message: "메시지가 잘렸습니다") }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        try take(MemoryLayout<T>.size).reduce(T(0)) { $0 << 8 | T($1) }
    }

    mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    mutating func u16() throws -> UInt16 { try integer(UInt16.self) }
    mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func bytes(_ count: Int) throws -> Data { try take(count) }
    mutating func rest() -> Data { (try? take(data.endIndex - offset)) ?? Data() }
}
