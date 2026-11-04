import CoreGraphics
import Testing
@testable import ModWindows

struct WindowLayoutTests {
    // Laptop (primary) with a menu bar + Dock, and a larger external display to its right, lower down.
    let laptop = WindowLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 875)
    )
    let external = WindowLayout.Screen(
        frame: CGRect(x: 1512, y: -235, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: -235, width: 2560, height: 1415)
    )
    // A third display above the laptop (top row comes first in yThenMinX order).
    let above = WindowLayout.Screen(
        frame: CGRect(x: 0, y: 982, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 982, width: 1920, height: 1055)
    )

    @Test func maximizeFillsTheVisibleFrameOfTheCurrentScreen() {
        let window = CGRect(x: 100, y: 200, width: 600, height: 400)
        #expect(WindowLayout.target(for: .maximize, window: window, screens: [laptop, external]) == laptop.visibleFrame)

        let onExternal = CGRect(x: 2000, y: 0, width: 800, height: 600)
        #expect(WindowLayout.target(for: .maximize, window: onExternal, screens: [laptop, external]) == external.visibleFrame)
    }

    @Test func halvesSplitTheVisibleFrameOfTheCurrentScreen() {
        let window = CGRect(x: 100, y: 200, width: 600, height: 400)
        #expect(WindowLayout.target(for: .leftHalf, window: window, screens: [laptop, external])
            == CGRect(x: 0, y: 70, width: 756, height: 875))
        #expect(WindowLayout.target(for: .rightHalf, window: window, screens: [laptop, external])
            == CGRect(x: 756, y: 70, width: 756, height: 875))

        // Odd widths: the halves still cover the whole screen without overlapping.
        let odd = WindowLayout.Screen(frame: CGRect(x: 0, y: 0, width: 1001, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1001, height: 775))
        let left = WindowLayout.target(for: .leftHalf, window: window, screens: [odd])!
        let right = WindowLayout.target(for: .rightHalf, window: window, screens: [odd])!
        #expect(left.maxX == right.minX && left.width + right.width == 1001)

        let onExternal = CGRect(x: 2000, y: 0, width: 800, height: 600)
        #expect(WindowLayout.target(for: .rightHalf, window: onExternal, screens: [laptop, external])
            == CGRect(x: 2792, y: -235, width: 1280, height: 1415))
    }

    @Test func windowSpanningScreensBelongsToTheLargerShare() {
        let window = CGRect(x: 1300, y: 100, width: 800, height: 400) // mostly on external
        #expect(WindowLayout.screenContaining(window, in: [laptop, external]) == external)
    }

    @Test func nextDisplayNeedsTwoScreens() {
        let window = CGRect(x: 100, y: 200, width: 600, height: 400)
        #expect(WindowLayout.target(for: .nextDisplay, window: window, screens: [laptop]) == nil)
    }

    @Test func maximizedWindowStaysMaximizedOnNextDisplay() {
        let target = WindowLayout.target(for: .nextDisplay, window: laptop.visibleFrame, screens: [laptop, external])
        #expect(target == external.visibleFrame)
    }

    @Test func twoScreensNextAndPreviousBothGoToTheOther() {
        let window = CGRect(x: 100, y: 200, width: 600, height: 400)
        let next = WindowLayout.target(for: .nextDisplay, window: window, screens: [laptop, external])
        let previous = WindowLayout.target(for: .previousDisplay, window: window, screens: [laptop, external])
        #expect(next.map { external.visibleFrame.contains($0) } == true)
        #expect(next == previous)
        #expect(next?.size == window.size)
    }

    @Test func orderIsTopRowFirstThenLeftToRight() {
        #expect(WindowLayout.order([external, laptop, above]) == [above, laptop, external])
    }

    @Test func threeScreensCycleInOrder() {
        let window = CGRect(x: 100, y: 200, width: 600, height: 400) // on laptop (index 1)
        let screens = [laptop, external, above]
        let next = WindowLayout.target(for: .nextDisplay, window: window, screens: screens)
        let previous = WindowLayout.target(for: .previousDisplay, window: window, screens: screens)
        #expect(next.map { external.visibleFrame.contains($0) } == true)
        #expect(previous.map { above.visibleFrame.contains($0) } == true)
    }

    @Test func constrainedPullsAnOversizedOrOffscreenWindowBackIn() {
        let bounds = CGRect(x: 0, y: 70, width: 1512, height: 875)
        #expect(WindowLayout.constrained(CGRect(x: 1400, y: 100, width: 300, height: 200), to: bounds).maxX == bounds.maxX)
        #expect(WindowLayout.constrained(CGRect(x: -50, y: 0, width: 300, height: 200), to: bounds).origin == CGPoint(x: 0, y: 70))
    }

    @Test func flipIsItsOwnInverse() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flipped = WindowLayout.flipped(rect, primaryScreenMaxY: 982)
        #expect(flipped == CGRect(x: 10, y: 762, width: 300, height: 200))
        #expect(WindowLayout.flipped(flipped, primaryScreenMaxY: 982) == rect)
    }
}

struct RestoreFrameTests {
    @Test func toleratesRoundingButNotMoves() {
        let frame = CGRect(x: 0, y: 25, width: 1512, height: 920)
        #expect(WindowLayout.isSameFrame(frame, frame.offsetBy(dx: 1, dy: -1)))
        #expect(!WindowLayout.isSameFrame(frame, frame.offsetBy(dx: 30, dy: 0)))
        #expect(!WindowLayout.isSameFrame(frame, CGRect(x: 0, y: 25, width: 1200, height: 920)))
    }
}

struct EdgeResizeSnapTests {
    // Cocoa coordinates: 1512×982 display, menu bar 25pt, Dock 60pt at the bottom.
    let visible = CGRect(x: 0, y: 60, width: 1512, height: 897)
    let window = CGRect(x: 200, y: 300, width: 800, height: 400)

    @Test func grabsOnlyTopOrBottomBorder() {
        #expect(WindowLayout.resizeEdge(at: CGPoint(x: 500, y: 702), window: window) == .top)
        #expect(WindowLayout.resizeEdge(at: CGPoint(x: 500, y: 698), window: window) == .top)
        #expect(WindowLayout.resizeEdge(at: CGPoint(x: 500, y: 695), window: window) == nil)   // title bar → move
        #expect(WindowLayout.resizeEdge(at: CGPoint(x: 500, y: 297), window: window) == .bottom)
        #expect(WindowLayout.resizeEdge(at: CGPoint(x: 500, y: 650), window: window) == nil)
        #expect(WindowLayout.resizeEdge(at: CGPoint(x: 1100, y: 700), window: window) == nil)  // beside the window
    }

    @Test func triggersNearMenuBarOrDockWithSlack() {
        let screen = WindowLayout.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: visible)
        #expect(WindowLayout.isAtScreenEdge(CGPoint(x: 500, y: 982), edge: .top, screen: screen))     // very top pixel
        #expect(WindowLayout.isAtScreenEdge(CGPoint(x: 500, y: 952), edge: .top, screen: screen))     // 5pt below menu bar
        #expect(!WindowLayout.isAtScreenEdge(CGPoint(x: 500, y: 900), edge: .top, screen: screen))
        #expect(WindowLayout.isAtScreenEdge(CGPoint(x: 500, y: 66), edge: .bottom, screen: screen))   // just above Dock
        #expect(WindowLayout.isAtScreenEdge(CGPoint(x: 500, y: -30), edge: .bottom, screen: screen))  // onto display below
        #expect(!WindowLayout.isAtScreenEdge(CGPoint(x: 500, y: -80), edge: .bottom, screen: screen))
        #expect(!WindowLayout.isAtScreenEdge(CGPoint(x: 500, y: 40), edge: .top, screen: screen))
    }

    @Test func keepsWidthAndFillsHeight() {
        #expect(WindowLayout.verticalFill(window, visibleFrame: visible) == CGRect(x: 200, y: 60, width: 800, height: 897))
    }
}

struct RestoreOnDragTests {
    @Test func keepsTopAndCursorRatio() {
        // Filled window 800 wide, cursor a quarter across; original 400×300.
        let filled = CGRect(x: 200, y: 60, width: 800, height: 897)
        let restored = WindowLayout.restoredOnDrag(filled, originalSize: CGSize(width: 400, height: 300), cursorX: 400)
        #expect(restored == CGRect(x: 300, y: 657, width: 400, height: 300))
        #expect(restored.maxY == filled.maxY)
    }
}

struct FilledMoveTests {
    let filled = CGRect(x: 200, y: 60, width: 800, height: 897)

    @Test func sidewaysKeepsFilledVerticalRestores() {
        let slid = filled.offsetBy(dx: 300, dy: 0)
        #expect(WindowLayout.isStillFilled(slid, filled: filled))
        #expect(!WindowLayout.movedVertically(slid, filled: filled))
        #expect(!WindowLayout.movedVertically(filled.offsetBy(dx: 300, dy: -4), filled: filled))  // jitter
        #expect(WindowLayout.movedVertically(filled.offsetBy(dx: 0, dy: -40), filled: filled))
        #expect(!WindowLayout.isStillFilled(CGRect(x: 200, y: 60, width: 800, height: 600), filled: filled))
    }
}
