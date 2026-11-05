import AppKit
import SwiftUI
import KeyboardShortcuts

/// Static metadata of a module. Available even while the module is disabled (no instance exists).
public struct ModuleDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// SF Symbol name.
    public let symbol: String
    public let requiredPermissions: Set<Permission>
    /// Whether the module contributes a section to the main popover (and thus appears in the order list).
    public let hasPopoverSection: Bool
    public let enabledByDefault: Bool
    /// Bundle IDs of standalone apps that conflict with this module when running at the same time.
    public let conflictingBundleIDs: [String]

    public init(
        id: String,
        displayName: String,
        symbol: String,
        requiredPermissions: Set<Permission> = [],
        hasPopoverSection: Bool = false,
        enabledByDefault: Bool = true,
        conflictingBundleIDs: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.symbol = symbol
        self.requiredPermissions = requiredPermissions
        self.hasPopoverSection = hasPopoverSection
        self.enabledByDefault = enabledByDefault
        self.conflictingBundleIDs = conflictingBundleIDs
    }
}

public enum ModuleStatus: Equatable, Sendable {
    case running
    case needsPermission(Permission)
    /// Running, but some feature is unavailable.
    case degraded(String)
    case error(String)
}

/// A global hotkey owned by a module. Registered while the module is active, removed when it is disabled.
public struct HotkeyDefinition {
    public let name: KeyboardShortcuts.Name
    public let title: String
    /// Shortcuts known to clash with apps or macOS, with a short explanation shown next to the recorder.
    public let conflicts: [KeyboardShortcuts.Shortcut: String]
    public let action: @MainActor () -> Void

    public init(
        name: KeyboardShortcuts.Name,
        title: String,
        conflicts: [KeyboardShortcuts.Shortcut: String] = [:],
        action: @escaping @MainActor () -> Void
    ) {
        self.name = name
        self.title = title
        self.conflicts = conflicts
        self.action = action
    }
}

/// Lets modules open/close the main popover. The app wires the closures to its status item.
@MainActor
public final class PopoverControl {
    public var isShown: () -> Bool = { false }
    public var show: () -> Void = {}
    public var close: () -> Void = {}
    /// Screen frame of the menu bar icon, for windows that point at it (e.g. a speech-bubble panel).
    public var anchorFrame: () -> NSRect? = { nil }

    public init() {}

    public func toggle() {
        isShown() ? close() : show()
    }
}

/// Services handed to a module on creation.
@MainActor
public struct ModuleContext {
    public let settings: ModuleSettings
    public let log: ModuleLog
    public let popover: PopoverControl

    public init(settings: ModuleSettings, log: ModuleLog, popover: PopoverControl) {
        self.settings = settings
        self.log = log
        self.popover = popover
    }
}

/// A feature module. An instance exists only while the module is enabled.
///
/// Contract: everything acquired in `start()` (event taps, watchers, timers, caches) must be released in `stop()`,
/// and the module must not be retained by static/global state, so that disabling it frees its memory.
@MainActor
public protocol TUModule: AnyObject, Observable {
    static var descriptor: ModuleDescriptor { get }

    init(context: ModuleContext)

    func start() async throws
    func stop() async

    var status: ModuleStatus { get }
    var hotkeys: [HotkeyDefinition] { get }

    /// Text appended next to the main menu bar icon (e.g. the clock).
    var statusItemText: String? { get }
    /// Overrides the main menu bar icon (e.g. the Awake state). Should be a template image.
    var statusItemImage: NSImage? { get }

    func makePopoverSection() -> AnyView?
    func makeSettingsView() -> AnyView

    /// Items for the status item's right-click menu (e.g. Awake mode). Shown above Settings/Quit.
    func makeQuickMenuItems() -> [NSMenuItem]

    /// Called right before the main popover is shown.
    func popoverWillShow()
    /// Called after the main popover has closed.
    func popoverDidClose()
    /// Key events while the popover is shown, offered to modules in popover order.
    /// Return `true` to consume the event.
    func handlePopoverKeyDown(_ event: NSEvent) -> Bool
}

public extension TUModule {
    var status: ModuleStatus { .running }
    var hotkeys: [HotkeyDefinition] { [] }
    var statusItemText: String? { nil }
    var statusItemImage: NSImage? { nil }
    func makePopoverSection() -> AnyView? { nil }
    func makeQuickMenuItems() -> [NSMenuItem] { [] }
    func popoverWillShow() {}
    func popoverDidClose() {}
    func handlePopoverKeyDown(_ event: NSEvent) -> Bool { false }
}
