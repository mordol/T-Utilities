import CoreGraphics
import Testing
@testable import ModSwitcher

struct KeyMachineTests {
    private func machine(_ trigger: SwitcherTrigger = .option) -> SwitcherKeyMachine {
        var machine = SwitcherKeyMachine()
        machine.trigger = trigger
        return machine
    }

    @Test func triggerTabOpensAndSwallows() {
        var m = machine()
        let decision = m.handle(.keyDown(.tab), flags: .maskAlternate)
        #expect(decision == .init(command: .step(backward: false), swallow: true))
        #expect(m.isActive)
    }

    @Test func shiftGoesBackward() {
        var m = machine()
        let decision = m.handle(.keyDown(.tab), flags: [.maskAlternate, .maskShift])
        #expect(decision.command == .step(backward: true))
        #expect(m.handle(.keyDown(.tab), flags: [.maskAlternate, .maskShift]).command == .step(backward: true))
        #expect(m.handle(.keyDown(.tab), flags: .maskAlternate).command == .step(backward: false))
    }

    @Test func otherEventsPassThroughWhenIdle() {
        var m = machine()
        #expect(m.handle(.keyDown(.tab), flags: []) == .passThrough)
        #expect(m.handle(.keyDown(.tab), flags: .maskCommand) == .passThrough)
        #expect(m.handle(.keyDown(.left), flags: .maskAlternate) == .passThrough)
        #expect(m.handle(.keyDown(.escape), flags: []) == .passThrough)
        #expect(m.handle(.flagsChanged, flags: []) == .passThrough)
        #expect(!m.isActive)
    }

    @Test func extraModifiersDoNotOpen() {
        var m = machine()
        #expect(m.handle(.keyDown(.tab), flags: [.maskAlternate, .maskCommand]) == .passThrough)
        #expect(m.handle(.keyDown(.tab), flags: [.maskAlternate, .maskControl]) == .passThrough)
        var cmd = machine(.command)
        #expect(cmd.handle(.keyDown(.tab), flags: [.maskCommand, .maskAlternate]) == .passThrough)
        #expect(cmd.handle(.keyDown(.tab), flags: [.maskCommand, .maskAlternate]) == .passThrough)
    }

    @Test func commandTriggerIgnoresOption() {
        var m = machine(.command)
        #expect(m.handle(.keyDown(.tab), flags: .maskAlternate) == .passThrough)
        #expect(m.handle(.keyDown(.tab), flags: .maskCommand).command == .step(backward: false))
    }

    @Test func arrowsMoveAndEscapeCancels() {
        var m = machine()
        _ = m.handle(.keyDown(.tab), flags: .maskAlternate)
        #expect(m.handle(.keyDown(.left), flags: .maskAlternate) == .init(command: .move(-1), swallow: true))
        #expect(m.handle(.keyDown(.right), flags: .maskAlternate) == .init(command: .move(1), swallow: true))
        #expect(m.handle(.keyDown(.escape), flags: .maskAlternate) == .init(command: .cancel, swallow: true))
        #expect(!m.isActive)
        // The release after cancelling must not commit.
        #expect(m.handle(.flagsChanged, flags: []) == .passThrough)
    }

    @Test func upDownMoveByRow() {
        var m = machine()
        #expect(m.handle(.keyDown(.up), flags: .maskAlternate) == .passThrough)
        _ = m.handle(.keyDown(.tab), flags: .maskAlternate)
        #expect(SwitcherKey(keyCode: 126) == .up)
        #expect(SwitcherKey(keyCode: 125) == .down)
        #expect(m.handle(.keyDown(.up), flags: .maskAlternate) == .init(command: .moveRow(-1), swallow: true))
        #expect(m.handle(.keyDown(.down), flags: .maskAlternate) == .init(command: .moveRow(1), swallow: true))
    }

    @Test func releasingTheTriggerCommits() {
        var m = machine()
        _ = m.handle(.keyDown(.tab), flags: .maskAlternate)
        // Releasing ⇧ alone keeps the switcher open.
        #expect(m.handle(.flagsChanged, flags: .maskAlternate) == .passThrough)
        #expect(m.handle(.flagsChanged, flags: []) == .init(command: .commit, swallow: false))
        #expect(!m.isActive)
    }

    @Test func otherKeysPassThroughWhileOpen() {
        var m = machine()
        _ = m.handle(.keyDown(.tab), flags: .maskAlternate)
        #expect(m.handle(.keyDown(.other), flags: .maskAlternate) == .passThrough)
        #expect(m.isActive)
    }

    @Test func missedReleaseCommitsOnNextKey() {
        var m = machine()
        _ = m.handle(.keyDown(.tab), flags: .maskAlternate)
        #expect(m.handle(.keyDown(.other), flags: []) == .init(command: .commit, swallow: false))
        #expect(!m.isActive)
    }

    @Test func resetForgetsTheSession() {
        var m = machine()
        _ = m.handle(.keyDown(.tab), flags: .maskAlternate)
        m.reset()
        #expect(m.handle(.flagsChanged, flags: []) == .passThrough)
    }

    @Test func keyCodes() {
        #expect(SwitcherKey(keyCode: 48) == .tab)
        #expect(SwitcherKey(keyCode: 123) == .left)
        #expect(SwitcherKey(keyCode: 124) == .right)
        #expect(SwitcherKey(keyCode: 53) == .escape)
        #expect(SwitcherKey(keyCode: 0) == .other)
    }
}

struct SwitcherLogicTests {
    @Test func selectionWrapsAround() {
        #expect(SwitcherLogic.moved(0, by: -1, count: 4) == 3)
        #expect(SwitcherLogic.moved(3, by: 1, count: 4) == 0)
        #expect(SwitcherLogic.moved(1, by: 1, count: 4) == 2)
        #expect(SwitcherLogic.moved(0, by: -9, count: 4) == 3)
        #expect(SwitcherLogic.moved(0, by: 1, count: 0) == 0)
    }

    @Test func rowMoveKeepsColumnAndWraps() {
        // 4 columns, 10 windows: rows 0-3, 4-7, 8-9.
        #expect(SwitcherLogic.movedRow(1, by: 1, columns: 4, count: 10) == 5)
        #expect(SwitcherLogic.movedRow(5, by: 1, columns: 4, count: 10) == 9)
        #expect(SwitcherLogic.movedRow(9, by: 1, columns: 4, count: 10) == 1)
        #expect(SwitcherLogic.movedRow(1, by: -1, columns: 4, count: 10) == 9)
        // The short last row has no column 2: skip it.
        #expect(SwitcherLogic.movedRow(6, by: 1, columns: 4, count: 10) == 2)
        #expect(SwitcherLogic.movedRow(2, by: -1, columns: 4, count: 10) == 6)
        // A single row stays put.
        #expect(SwitcherLogic.movedRow(2, by: 1, columns: 4, count: 3) == 2)
        #expect(SwitcherLogic.movedRow(0, by: 1, columns: 4, count: 0) == 0)
    }

    @Test func hoverSelectsOnlyInHoverMode() {
        #expect(SwitcherLogic.selectionAfterHover(1, hovered: 3, mode: .hover) == 3)
        #expect(SwitcherLogic.selectionAfterHover(1, hovered: 3, mode: .click) == 1)
    }

    @Test func selectionAfterRemovingAWindow() {
        // Removing before the selection keeps the same window selected.
        #expect(SwitcherLogic.selectionAfterRemoving(0, selected: 2, count: 4) == 1)
        // Removing after it changes nothing.
        #expect(SwitcherLogic.selectionAfterRemoving(3, selected: 1, count: 4) == 1)
        // Removing the selected window selects its successor, or the new last one at the end.
        #expect(SwitcherLogic.selectionAfterRemoving(1, selected: 1, count: 4) == 1)
        #expect(SwitcherLogic.selectionAfterRemoving(4, selected: 4, count: 4) == 3)
        #expect(SwitcherLogic.selectionAfterRemoving(0, selected: 0, count: 0) == 0)
    }

    @Test func initialSelection() {
        #expect(SwitcherLogic.initialSelection(count: 5, backward: false) == 1)
        #expect(SwitcherLogic.initialSelection(count: 5, backward: true) == 4)
        #expect(SwitcherLogic.initialSelection(count: 1, backward: false) == 0)
        #expect(SwitcherLogic.initialSelection(count: 0, backward: true) == 0)
    }

    @Test func gridColumns() {
        #expect(SwitcherLogic.gridColumns(count: 3, availableWidth: 1000, cellWidth: 200, spacing: 10) == 3)
        #expect(SwitcherLogic.gridColumns(count: 20, availableWidth: 1000, cellWidth: 200, spacing: 10) == 4)
        #expect(SwitcherLogic.gridColumns(count: 20, availableWidth: 50, cellWidth: 200, spacing: 10) == 1)
    }

    @Test func displayOrderIsFrontToBackThenUnplacedThenMinimized() {
        let order = SwitcherLogic.displayOrder(
            zOrder: [3, nil, 0, nil, 1],
            isMinimized: [false, true, false, false, false]
        )
        #expect(order == [2, 4, 0, 3, 1])
    }

    @Test func displayOrderIsStableForTies() {
        #expect(SwitcherLogic.displayOrder(zOrder: [nil, nil, nil], isMinimized: [true, true, true]) == [0, 1, 2])
    }
}

struct WindowMatchingTests {
    private func snapshot(_ pid: pid_t, _ title: String, _ frame: CGRect, minimized: Bool = false) -> WindowSnapshot {
        WindowSnapshot(pid: pid, title: title, frame: frame, isMinimized: minimized)
    }

    private func candidate(_ id: CGWindowID, _ pid: pid_t, _ title: String, _ frame: CGRect) -> WindowCandidate {
        WindowCandidate(windowID: id, pid: pid, title: title, frame: frame)
    }

    let a = CGRect(x: 0, y: 0, width: 800, height: 600)
    let b = CGRect(x: 100, y: 100, width: 500, height: 400)

    @Test func matchesByPidAndFrame() {
        let result = SwitcherLogic.match(
            [snapshot(1, "x", b), snapshot(2, "y", a)],
            to: [candidate(10, 2, "", a), candidate(11, 1, "", b)]
        )
        #expect(result.map { $0?.windowID } == [11, 10])
    }

    @Test func toleratesRoundingButNotRealDifferences() {
        let near = a.offsetBy(dx: 1.5, dy: -1)
        let far = a.offsetBy(dx: 10, dy: 0)
        #expect(SwitcherLogic.match([snapshot(1, "", a)], to: [candidate(10, 1, "", near)])[0]?.windowID == 10)
        #expect(SwitcherLogic.match([snapshot(1, "", a)], to: [candidate(10, 1, "", far)])[0] == nil)
    }

    @Test func titleBreaksTiesBetweenIdenticalFrames() {
        let result = SwitcherLogic.match(
            [snapshot(1, "second", a), snapshot(1, "first", a)],
            to: [candidate(10, 1, "first", a), candidate(11, 1, "second", a)]
        )
        #expect(result.map { $0?.windowID } == [11, 10])
    }

    @Test func identicalFramesWithoutTitlesUseZOrderAndEachCandidateOnce() {
        let result = SwitcherLogic.match(
            [snapshot(1, "", a), snapshot(1, "", a), snapshot(1, "", a)],
            to: [candidate(10, 1, "", a), candidate(11, 1, "", a)]
        )
        #expect(result.map { $0?.windowID } == [10, 11, nil])
    }

    @Test func minimizedAndOtherPidsNeverMatch() {
        let result = SwitcherLogic.match(
            [snapshot(1, "", a, minimized: true), snapshot(3, "", a)],
            to: [candidate(10, 1, "", a), candidate(11, 2, "", a)]
        )
        #expect(result.allSatisfy { $0 == nil })
    }
}
