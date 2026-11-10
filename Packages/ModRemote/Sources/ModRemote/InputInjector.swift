import CoreGraphics
import Foundation

/// Host side input: replays the client's events with CGEvent (needs Accessibility). Not an event tap, so a
/// missing permission only makes the events vanish; it can never stall the host's input.
@MainActor
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<MouseButton> = []
    private var keysDown: Set<UInt16> = []
    private var flags: CGEventFlags = []
    private var location = CGPoint.zero

    func apply(_ input: RemoteInput) {
        switch input {
        case .mouseMove(let x, let y):
            location = Self.point(x, y)
            let type: CGEventType = if buttonsDown.contains(.left) {
                .leftMouseDragged
            } else if buttonsDown.contains(.right) {
                .rightMouseDragged
            } else if buttonsDown.contains(.other) {
                .otherMouseDragged
            } else {
                .mouseMoved
            }
            postMouse(type, button: buttonsDown.first ?? .left, clickCount: 0)
        case .mouseDown(let button, let x, let y, let clickCount):
            location = Self.point(x, y)
            buttonsDown.insert(button)
            postMouse(Self.downType(button), button: button, clickCount: clickCount)
        case .mouseUp(let button, let x, let y, let clickCount):
            location = Self.point(x, y)
            buttonsDown.remove(button)
            postMouse(Self.upType(button), button: button, clickCount: clickCount)
        case .scroll(let dx, let dy, let isPrecise):
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: isPrecise ? .pixel : .line,
                wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
            )
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        case .key(let code, let isDown, let isRepeat, let rawFlags):
            flags = CGEventFlags(rawValue: rawFlags)
            if isDown { keysDown.insert(code) } else { keysDown.remove(code) }
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
            event?.flags = flags
            if isRepeat { event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Session over: nothing may stay pressed on the host.
    func releaseAll() {
        for button in buttonsDown {
            postMouse(Self.upType(button), button: button, clickCount: 1)
        }
        buttonsDown = []
        flags = []
        for code in keysDown {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
        keysDown = []
    }

    private func postMouse(_ type: CGEventType, button: MouseButton, clickCount: UInt8) {
        let cgButton: CGMouseButton = switch button {
        case .left: .left
        case .right: .right
        case .other: .center
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton) else {
            return
        }
        event.flags = flags
        if clickCount > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        event.post(tap: .cghidEventTap)
    }

    /// Normalized stream position → global display coordinates of the captured (main) display.
    private static func point(_ x: Float, _ y: Float) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let clampedX = min(max(CGFloat(x), 0), 1), clampedY = min(max(CGFloat(y), 0), 1)
        return CGPoint(x: bounds.minX + clampedX * (bounds.width - 1), y: bounds.minY + clampedY * (bounds.height - 1))
    }

    private static func downType(_ button: MouseButton) -> CGEventType {
        switch button {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .other: .otherMouseDown
        }
    }

    private static func upType(_ button: MouseButton) -> CGEventType {
        switch button {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .other: .otherMouseUp
        }
    }
}
