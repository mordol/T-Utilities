import AppKit
import TUCore

/// Session event tap behind the switcher. Only trigger+Tab and, while the switcher is open, ←/→/Esc/Tab are
/// swallowed; every other event passes through untouched. The UI and Accessibility work runs after the callback
/// returns (the callback only runs `SwitcherKeyMachine`).
@MainActor
final class SwitcherTapController {
    /// Called on the main actor after the tap callback returned, in event order.
    var onCommand: ((SwitcherCommand) -> Void)?

    var trigger: SwitcherTrigger = .option {
        didSet {
            guard trigger != oldValue else { return }
            machine.trigger = trigger
            // A half-finished switch with the old trigger would never see its release.
            cancelActiveSession()
        }
    }

    private var machine = SwitcherKeyMachine()
    private lazy var tap: SupervisedEventTap = {
        let tap = SupervisedEventTap(types: [.keyDown, .flagsChanged], probeType: .keyDown) { [weak self] type, event in
            self?.handle(type, event) ?? false
        }
        tap.onUninstall = { [weak self] in self?.cancelActiveSession() }
        // Events were lost, so the modifier release may have been too.
        tap.onReenable = { [weak self] in self?.cancelActiveSession() }
        return tap
    }()

    /// Installs the tap when possible and removes it as soon as event access is lost (see `SupervisedEventTap`).
    func start() {
        machine.trigger = trigger
        tap.start()
    }

    func stop() {
        tap.stop()
    }

    /// Returns whether the event is swallowed.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let input: SwitcherKeyMachine.Input
        switch type {
        case .keyDown:
            input = .keyDown(SwitcherKey(keyCode: event.getIntegerValueField(.keyboardEventKeycode)))
        case .flagsChanged:
            input = .flagsChanged
        default:
            return false
        }
        let decision = machine.handle(input, flags: event.flags)
        if let command = decision.command { dispatch(command) }
        return decision.swallow
    }

    private func cancelActiveSession() {
        guard machine.isActive else { return }
        machine.reset()
        dispatch(.cancel)
    }

    /// FIFO on the main queue, so show → commit of a quick tap keeps its order.
    private func dispatch(_ command: SwitcherCommand) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onCommand?(command) }
        }
    }
}
