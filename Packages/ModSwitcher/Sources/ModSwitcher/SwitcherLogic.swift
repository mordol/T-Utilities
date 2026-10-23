import CoreGraphics

/// Modifier that, held with Tab, opens the switcher.
enum SwitcherTrigger: String, CaseIterable, Identifiable, Sendable {
    case option
    case command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .option: "⌥Tab"
        case .command: "⌘Tab"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .command: .maskCommand
        }
    }

    /// Modifiers that make a Tab press something else (⌃Tab, ⌘⌥Tab …). ⇧ only means "backward".
    fileprivate var foreignModifiers: CGEventFlags {
        var others: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        others.remove(flag)
        return others
    }

    var conflictWarning: String? {
        switch self {
        case .option: nil
        case .command: "⌘Tab은 macOS의 앱 전환기를 대체합니다. 이 모듈을 켜 두는 동안 기본 앱 전환기는 나타나지 않습니다."
        }
    }
}

/// What the mouse does over the switcher. A click always switches; `hover` also selects the window under the pointer.
enum SwitcherMouseMode: String, CaseIterable, Identifiable, Sendable {
    case click
    case hover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .click: "클릭으로 전환"
        case .hover: "호버로 선택"
        }
    }
}

/// What the switcher UI should do, decided from the keyboard.
enum SwitcherCommand: Equatable, Sendable {
    /// Open the switcher, or move to the next/previous window when it is already open.
    case step(backward: Bool)
    case move(Int)
    /// Up/down one row of the grid.
    case moveRow(Int)
    case cancel
    /// The trigger modifier was released: focus the selected window.
    case commit
}

/// Key codes the switcher cares about; everything else is `.other`.
enum SwitcherKey: Equatable, Sendable {
    case tab, left, right, up, down, escape, other

    init(keyCode: Int64) {
        switch keyCode {
        case 48: self = .tab
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        case 53: self = .escape
        default: self = .other
        }
    }
}

/// Decides, per event, whether the event tap swallows it and which command to run.
/// Runs inside the event tap callback and sees every keystroke, so it does nothing but compare a few flags.
struct SwitcherKeyMachine: Sendable {
    enum Input: Equatable, Sendable {
        case keyDown(SwitcherKey)
        case flagsChanged
    }

    struct Decision: Equatable, Sendable {
        var command: SwitcherCommand?
        var swallow: Bool

        static let passThrough = Decision(command: nil, swallow: false)
    }

    var trigger: SwitcherTrigger = .option
    private(set) var isActive = false

    mutating func reset() {
        isActive = false
    }

    mutating func handle(_ input: Input, flags: CGEventFlags) -> Decision {
        let triggerHeld = flags.contains(trigger.flag)
        switch input {
        case .flagsChanged:
            guard isActive, !triggerHeld else { return .passThrough }
            isActive = false
            return Decision(command: .commit, swallow: false)

        case .keyDown(let key):
            if !isActive {
                guard key == .tab, triggerHeld, flags.isDisjoint(with: trigger.foreignModifiers) else { return .passThrough }
                isActive = true
                return Decision(command: .step(backward: flags.contains(.maskShift)), swallow: true)
            }
            // The modifier release was missed (e.g. the tap was disabled): finish instead of eating keys.
            guard triggerHeld else {
                isActive = false
                return Decision(command: .commit, swallow: false)
            }
            switch key {
            case .tab:
                guard flags.isDisjoint(with: trigger.foreignModifiers) else { return .passThrough }
                return Decision(command: .step(backward: flags.contains(.maskShift)), swallow: true)
            case .left: return Decision(command: .move(-1), swallow: true)
            case .right: return Decision(command: .move(1), swallow: true)
            case .up: return Decision(command: .moveRow(-1), swallow: true)
            case .down: return Decision(command: .moveRow(1), swallow: true)
            case .escape:
                isActive = false
                return Decision(command: .cancel, swallow: true)
            case .other: return .passThrough
            }
        }
    }
}

/// One window as read through the Accessibility API.
struct WindowSnapshot: Equatable, Sendable {
    let pid: pid_t
    let title: String
    /// Accessibility coordinates (top-left origin).
    let frame: CGRect
    let isMinimized: Bool
}

/// One on-screen window from CGWindowList, front to back.
struct WindowCandidate: Equatable, Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let frame: CGRect
}

enum SwitcherLogic {
    /// Moves a selection by `delta` and wraps around both ends.
    static func moved(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// Moves a selection by `delta` rows of a grid with `columns` columns, keeping the column and wrapping
    /// around; rows of a short last row that lack the column are skipped.
    static func movedRow(_ index: Int, by delta: Int, columns: Int, count: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        let column = index % columns
        var row = index / columns
        repeat {
            row = ((row + delta) % rows + rows) % rows
        } while row * columns + column >= count
        return row * columns + column
    }

    /// The pointer entering a window selects it only in hover mode.
    static func selectionAfterHover(_ selected: Int, hovered: Int, mode: SwitcherMouseMode) -> Int {
        mode == .hover ? hovered : selected
    }

    /// Selection after the window at `removed` left the list, which now has `count` windows: it stays on the
    /// same window, or on its successor (the new last one at the end) when the selected window was removed.
    static func selectionAfterRemoving(_ removed: Int, selected: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        if selected > removed { return selected - 1 }
        return min(selected, count - 1)
    }

    /// Forward starts on the previously used window (the second one), backward on the last one.
    static func initialSelection(count: Int, backward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return backward ? count - 1 : min(1, count - 1)
    }

    /// Columns of the wrapping grid: as many as fit in `availableWidth`, never more than there are windows.
    static func gridColumns(count: Int, availableWidth: CGFloat, cellWidth: CGFloat, spacing: CGFloat) -> Int {
        let fit = Int((availableWidth + spacing) / (cellWidth + spacing))
        return max(1, min(count, fit))
    }

    /// Frames of the same window read through AX and CGWindowList differ by rounding at most.
    static let frameTolerance: CGFloat = 2

    static func isSameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }

    /// Pairs each AX window with the CGWindowList entry of the same window (public data only: pid + frame, title
    /// as tie-breaker). Every candidate is used once; a window without a match (minimized, other Space) gets nil.
    static func match(_ windows: [WindowSnapshot], to candidates: [WindowCandidate]) -> [WindowCandidate?] {
        var used = Set<CGWindowID>()
        return windows.map { window in
            guard !window.isMinimized else { return nil }
            let sameFrame = candidates.filter {
                $0.pid == window.pid && !used.contains($0.windowID) && isSameFrame($0.frame, window.frame)
            }
            let found = sameFrame.first { !window.title.isEmpty && $0.title == window.title } ?? sameFrame.first
            if let found { used.insert(found.windowID) }
            return found
        }
    }

    /// Indices in display order: on-screen windows by z-order (front first), then windows that could not be
    /// placed in the z-order, then minimized ones. `zOrder` is the index into the CGWindowList, nil if unmatched.
    static func displayOrder(zOrder: [Int?], isMinimized: [Bool]) -> [Int] {
        func tier(_ index: Int) -> Int {
            if isMinimized[index] { return 2 }
            return zOrder[index] == nil ? 1 : 0
        }
        return zOrder.indices.sorted { a, b in
            (tier(a), zOrder[a] ?? 0, a) < (tier(b), zOrder[b] ?? 0, b)
        }
    }
}
