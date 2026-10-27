import AppKit
import TUCore

// Idea from easy-move-resize (MIT, © Daniel Marcotte): hold a modifier and drag anywhere in a window to move it,
// right-drag to resize it. https://github.com/dmarcotte/easy-move-resize

/// Session event tap behind modifier-drag. It swallows the armed mouse-down/drag/up so the app under the
/// cursor never sees the click, and moves/resizes the window under the cursor through the Accessibility API.
@MainActor
final class ModifierDragController {
    private enum Kind { case move, resize(ModifierDragLogic.Region) }

    private struct Session {
        let writer: FrameWriter
        let kind: Kind
        let startFrame: CGRect
        let startCursor: CGPoint
    }

    var modifiers: DragModifiers = .default
    /// Armed left double-click on a window; called on the main actor after the tap returns.
    var onDoubleClick: ((AXWindow) -> Void)?

    private var session: Session?
    /// The double-click's own drag/up are swallowed too, so the app never sees half a click.
    private var swallowsUntilUp = false
    private lazy var tap: SupervisedEventTap = {
        let tap = SupervisedEventTap(
            types: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp],
            probeType: .leftMouseDown
        ) { [weak self] type, event in self?.handle(type, event) ?? false }
        tap.onUninstall = { [weak self] in
            self?.session?.writer.finish()
            self?.session = nil
        }
        return tap
    }()

    /// Installs the tap when possible and removes it as soon as event access is lost (see `SupervisedEventTap`).
    func start() {
        tap.start()
    }

    func stop() {
        tap.stop()
    }

    /// Returns whether the event is swallowed.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            session?.writer.finish()
            session = nil
            swallowsUntilUp = false
            let action = ModifierDragLogic.mouseDownAction(
                isRightButton: type == .rightMouseDown,
                clickCount: event.getIntegerValueField(.mouseEventClickState),
                modifiersMatch: modifiers.matches(event.flags)
            )
            switch action {
            case .passThrough:
                return false
            case .toggleMaximize:
                guard let window = AXWindow.at(event.location), !window.isSheet else { return false }
                swallowsUntilUp = true
                // Resizing is a synchronous AX round trip; keep it out of the tap callback.
                Task { @MainActor [weak self] in self?.onDoubleClick?(window) }
                return true
            case .move, .resize:
                guard let started = begin(isResize: action == .resize, at: event.location) else { return false }
                session = started
                return true
            }
        case .leftMouseDragged, .rightMouseDragged:
            if swallowsUntilUp { return true }
            guard let session else { return false }
            update(session, cursor: event.location)
            return true
        case .leftMouseUp, .rightMouseUp:
            if swallowsUntilUp {
                swallowsUntilUp = false
                return true
            }
            guard let session else { return false }
            session.writer.finish()
            self.session = nil
            return true
        default:
            return false
        }
    }

    private func begin(isResize: Bool, at cursor: CGPoint) -> Session? {
        guard let window = AXWindow.at(cursor), !window.isSheet, let frame = window.frame else { return nil }
        if isResize, !window.isResizable { return nil }
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        let kind: Kind = isResize ? .resize(ModifierDragLogic.region(of: cursor, in: frame)) : .move
        let writer = FrameWriter(element: window.element, app: window.app, startFrame: frame)
        return Session(writer: writer, kind: kind, startFrame: frame, startCursor: cursor)
    }

    private func update(_ session: Session, cursor: CGPoint) {
        let delta = CGPoint(x: cursor.x - session.startCursor.x, y: cursor.y - session.startCursor.y)
        switch session.kind {
        case .move:
            session.writer.submit(ModifierDragLogic.moved(session.startFrame, by: delta))
        case .resize(let region):
            session.writer.submit(ModifierDragLogic.resized(session.startFrame, region: region, by: delta))
        }
    }
}

/// Applies window frames off the main thread. Each Accessibility write is a synchronous round trip to the
/// target app, so doing them inside the event tap stalls the whole mouse; here only the newest frame is kept
/// and unchanged size/position are not rewritten.
private final class FrameWriter: @unchecked Sendable {
    private static let enhancedUserInterface = "AXEnhancedUserInterface"

    private let element: AXUIElement
    private let app: AXUIElement
    private let queue = DispatchQueue(label: "com.taegyu.tutilities.modifier-drag", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: CGRect?
    private var scheduled = false
    private var applied: CGRect
    private let restoreEnhanced: Bool

    /// AXEnhancedUserInterface makes AX writes animate, which is what makes live resizing crawl in some apps.
    init(element: AXUIElement, app: AXUIElement, startFrame: CGRect) {
        self.element = element
        self.app = app
        applied = startFrame
        var value: CFTypeRef?
        let enabled = AXUIElementCopyAttributeValue(app, Self.enhancedUserInterface as CFString, &value) == .success
            && (value as? Bool) == true
        restoreEnhanced = enabled
        if enabled { AXUIElementSetAttributeValue(app, Self.enhancedUserInterface as CFString, kCFBooleanFalse) }
    }

    func submit(_ frame: CGRect) {
        lock.lock()
        pending = frame
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func finish() {
        guard restoreEnhanced else { return }
        queue.async { AXUIElementSetAttributeValue(self.app, Self.enhancedUserInterface as CFString, kCFBooleanTrue) }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let target = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            apply(target)
        }
    }

    private func apply(_ target: CGRect) {
        if target.size != applied.size {
            var size = target.size
            if let value = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
            }
        }
        if target.origin != applied.origin {
            var origin = target.origin
            if let value = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
            }
        }
        applied = target
    }
}
