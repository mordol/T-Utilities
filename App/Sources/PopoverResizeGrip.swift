import AppKit
import SwiftUI
import TUCore

/// Invisible corner grip that resizes the popover. The popover hangs from the menu bar, so it grows downward
/// and symmetrically in width: width changes by twice the horizontal drag distance, which keeps the
/// grip under the cursor. Tracks `NSEvent.mouseLocation` because the grip itself moves while dragging.
struct PopoverResizeGrip: NSViewRepresentable {
    @Binding var width: Double
    @Binding var listHeight: Double

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.onDrag = { start, mouse in
            width = (start.width + 2 * Double(mouse.x - start.mouse.x)).clamped(to: PopoverSize.widthRange)
            listHeight = min(start.listHeight + Double(start.mouse.y - mouse.y), start.maxListHeight)
                .clamped(to: PopoverSize.listHeightRange)
        }
        view.current = { (width, listHeight) }
        return view
    }

    func updateNSView(_ view: GripView, context: Context) {}

    struct DragStart {
        let mouse: CGPoint
        let width: Double
        let listHeight: Double
        let maxListHeight: Double
    }

    final class GripView: NSView {
        var onDrag: ((_ start: DragStart, _ mouse: CGPoint) -> Void)?
        var current: (() -> (Double, Double))?
        private var start: DragStart?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        override func mouseDown(with event: NSEvent) {
            let (width, listHeight) = current?() ?? (0, 0)
            // The popover grows downward: stop at the bottom of the screen's usable area.
            var maxListHeight = Double.infinity
            if let window, let screen = window.screen {
                maxListHeight = listHeight + Double(window.frame.minY - screen.visibleFrame.minY - 8)
            }
            start = DragStart(mouse: NSEvent.mouseLocation, width: width, listHeight: listHeight, maxListHeight: maxListHeight)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            onDrag?(start, NSEvent.mouseLocation)
        }

        override func mouseUp(with event: NSEvent) { start = nil }
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<CGFloat>) -> Double {
        min(max(self, Double(range.lowerBound)), Double(range.upperBound))
    }
}
