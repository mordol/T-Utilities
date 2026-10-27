import CoreGraphics
import Foundation

/// A session event tap that removes itself as soon as event access is lost. Every module event tap must use
/// this (see Docs/MODULES.md): an active tap whose app loses Accessibility (revoked, or the running bundle
/// replaced by an update or rebuild) stalls that input system-wide, and `AXIsProcessTrusted` can report a
/// stale grant — so a supervisor probes with a real throwaway tap every `checkInterval`.
///
/// The tap retains this object while installed, so the C callback can never see a freed object; call `stop()`
/// (the owning module's `stop()`) to release it.
@MainActor
public final class SupervisedEventTap {
    /// Returns true to swallow the event. May modify the event in place. Runs on the main thread.
    public typealias Handler = @MainActor (CGEventType, CGEvent) -> Bool

    /// How long input can stall after Accessibility is lost while the tap is active.
    public static let checkInterval: Duration = .seconds(3)

    private let mask: CGEventMask
    private let probeType: CGEventType
    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var supervisor: Task<Void, Never>?

    /// Called after the tap was removed (stop or lost access), e.g. to end an in-progress gesture.
    public var onUninstall: (@MainActor () -> Void)?
    /// Called after macOS disabled the tap for a moment (timeout or user input) and it was re-enabled;
    /// events in between were lost.
    public var onReenable: (@MainActor () -> Void)?
    /// Called whenever `isInstalled` changes.
    public var onInstalledChange: (@MainActor (Bool) -> Void)?

    public var isInstalled: Bool { tap != nil }

    /// - Parameter probeType: event type used for the access probe; use one from `types`.
    public init(types: [CGEventType], probeType: CGEventType, handler: @escaping Handler) {
        mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        self.probeType = probeType
        self.handler = handler
    }

    /// Installs the tap now if possible and keeps supervising until `stop()`.
    public func start() {
        guard supervisor == nil else { return }
        install()
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkInterval)
                guard let self, !Task.isCancelled else { return }
                if isInstalled {
                    if await !Self.canCreateEventTap(probeType) { uninstall() }
                } else {
                    install()
                }
            }
        }
    }

    public func stop() {
        supervisor?.cancel()
        supervisor = nil
        uninstall()
    }

    private func install() {
        guard tap == nil else { return }
        let info = Unmanaged.passRetained(self)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.callback, userInfo: info.toOpaque()
        ) else {
            info.release()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        onInstalledChange?(true)
    }

    private func uninstall() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        onUninstall?()
        onInstalledChange?(false)
        Unmanaged.passUnretained(self).release() // balances passRetained in install(); callers still hold self
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<SupervisedEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        nonisolated(unsafe) let event = event
        // The tap's run loop source is on the main run loop, so this runs on the main thread.
        let swallow = MainActor.assumeIsolated { owner.handle(type, event) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onReenable?()
            return false
        default:
            return handler(type, event)
        }
    }

    /// Creates and immediately discards a tap off the main thread; fails once Accessibility is gone.
    private nonisolated static func canCreateEventTap(_ type: CGEventType) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let probe = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(1) << type.rawValue,
                callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil
            ) else { return false }
            CFMachPortInvalidate(probe)
            return true
        }.value
    }
}
