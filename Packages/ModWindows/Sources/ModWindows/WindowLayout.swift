import CoreGraphics

/// Pure geometry for the supported actions, in Cocoa screen coordinates (origin bottom-left of the
/// primary display). Logic follows Rectangle's ScreenDetection / MaximizeCalculation /
/// NextPrevDisplayCalculation with their default settings.
enum WindowLayout {
    struct Screen: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    /// AX frames come back rounded; a couple of points of slack still means "unchanged".
    static func isSameFrame(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Undo of Fill Height (AX coordinates): the original top and height, the current left and width.
    static func restoredHeight(_ current: CGRect, original: CGRect) -> CGRect {
        CGRect(x: current.minX, y: original.minY, width: current.width, height: original.height)
    }

    // MARK: Edge-resize snap (top/bottom edge dragged to the screen edge → full visible height)

    enum ResizeEdge: Sendable { case top, bottom }

    /// Which horizontal edge a drag starting at `point` grabs, if any. macOS' resize area straddles the border;
    /// inside the window it is only a few points deep, deeper than that is the title bar (a move).
    static func resizeEdge(at point: CGPoint, window: CGRect, outside: CGFloat = 6, inside: CGFloat = 3) -> ResizeEdge? {
        guard point.x >= window.minX - outside, point.x <= window.maxX + outside else { return nil }
        if point.y <= window.maxY + outside, point.y >= window.maxY - inside { return .top }
        if point.y >= window.minY - outside, point.y <= window.minY + inside { return .bottom }
        return nil
    }

    /// Cursor is at the menu bar / Dock side of the window's screen. `inside` makes it trigger slightly before
    /// the edge; `outside` keeps it active past the edge, e.g. onto a display stacked above or below.
    static func isAtScreenEdge(
        _ point: CGPoint, edge: ResizeEdge, screen: Screen, inside: CGFloat = 8, outside: CGFloat = 40
    ) -> Bool {
        guard point.x >= screen.frame.minX - outside, point.x <= screen.frame.maxX + outside else { return false }
        switch edge {
        case .top: return point.y >= screen.visibleFrame.maxY - inside && point.y <= screen.frame.maxY + outside
        case .bottom: return point.y <= screen.visibleFrame.minY + inside && point.y >= screen.frame.minY - outside
        }
    }

    /// A height-filled window is still "filled" wherever it sits horizontally: same size, same vertical span.
    static func isStillFilled(_ window: CGRect, filled: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(window.width - filled.width) <= tolerance && abs(window.height - filled.height) <= tolerance
            && abs(window.minY - filled.minY) <= tolerance
    }

    /// Sliding a filled window sideways keeps its height; moving it up/down (beyond hand jitter) restores it.
    static func movedVertically(_ window: CGRect, filled: CGRect, threshold: CGFloat = 10) -> Bool {
        abs(window.minY - filled.minY) > threshold
    }

    /// Previous size for a filled window that started moving: top edge stays (title bar under the cursor) and
    /// the cursor keeps its relative horizontal position, as macOS does when dragging a tiled window away.
    static func restoredOnDrag(_ window: CGRect, originalSize: CGSize, cursorX: CGFloat) -> CGRect {
        let ratio = window.width > 0 ? min(1, max(0, (cursorX - window.minX) / window.width)) : 0.5
        return CGRect(
            x: cursorX - ratio * originalSize.width, y: window.maxY - originalSize.height,
            width: originalSize.width, height: originalSize.height
        )
    }

    /// Same x and width, full visible height.
    static func verticalFill(_ window: CGRect, visibleFrame: CGRect) -> CGRect {
        CGRect(x: window.minX, y: visibleFrame.minY, width: window.width, height: visibleFrame.height)
    }

    enum Action: Sendable {
        case maximize, leftHalf, rightHalf, fillHeight, nextDisplay, previousDisplay
    }

    /// Target frame for `window`, or nil when the action does not apply (e.g. single display).
    static func target(for action: Action, window: CGRect, screens: [Screen]) -> CGRect? {
        let ordered = order(screens)
        guard let current = screenContaining(window, in: ordered) else { return nil }

        switch action {
        case .maximize:
            return current.visibleFrame
        case .fillHeight:
            let area = current.visibleFrame
            return CGRect(x: window.minX, y: area.minY, width: window.width, height: area.height)
        case .leftHalf, .rightHalf:
            let area = current.visibleFrame
            let leftWidth = (area.width / 2).rounded(.down)
            return action == .leftHalf
                ? CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height)
                : CGRect(x: area.minX + leftWidth, y: area.minY, width: area.width - leftWidth, height: area.height)
        case .nextDisplay, .previousDisplay:
            guard ordered.count > 1, let index = ordered.firstIndex(of: current) else { return nil }
            let step = action == .nextDisplay ? 1 : ordered.count - 1
            let destination = ordered[(index + step) % ordered.count]
            let transferred = DisplayTransfer.transferredRect(
                window: window, source: current.visibleFrame, destination: destination.visibleFrame
            )
            // A maximized window stays maximized on the next display.
            return transferred.sharedEdges == .all ? destination.visibleFrame : transferred.rect
        }
    }

    /// Rectangle's default ordering (`yThenMinX`): top row first, then left to right.
    static func order(_ screens: [Screen]) -> [Screen] {
        screens.sorted { first, second in
            if second.frame.maxY <= first.frame.minY { return true }
            if first.frame.maxY <= second.frame.minY { return false }
            return first.frame.minX < second.frame.minX
        }
    }

    /// The screen that fully contains the window, else the one with the largest share of it.
    static func screenContaining(_ window: CGRect, in screens: [Screen]) -> Screen? {
        if let containing = screens.first(where: { $0.frame.contains(window) }) {
            return containing
        }
        return screens.max { overlap(window, $0.frame) < overlap(window, $1.frame) } ?? screens.first
    }

    private static func overlap(_ window: CGRect, _ frame: CGRect) -> CGFloat {
        let intersection = window.intersection(frame)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    /// Keeps a window that refused the requested size inside the visible frame (Rectangle's BestEffortWindowMover).
    static func constrained(_ window: CGRect, to bounds: CGRect) -> CGRect {
        var result = window
        if result.minX < bounds.minX {
            result.origin.x = bounds.minX
        } else if result.maxX > bounds.maxX {
            result.origin.x = max(bounds.minX, bounds.maxX - result.width)
        }
        if result.minY < bounds.minY {
            result.origin.y = bounds.minY
        } else if result.maxY > bounds.maxY {
            result.origin.y = max(bounds.minY, bounds.maxY - result.height)
        }
        return result
    }

    /// Converts between Cocoa (bottom-left origin) and Accessibility (top-left origin) coordinates.
    /// The conversion is its own inverse.
    static func flipped(_ rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenMaxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
