import Foundation
import KeyboardShortcuts

/// Owns module lifecycles. Only module *types* are kept permanently; an instance is created when a module is
/// enabled and dropped when it is disabled, so a disabled module holds no memory.
@MainActor
@Observable
public final class ModuleRegistry {
    public let descriptors: [ModuleDescriptor]
    public private(set) var enabledIDs: Set<String>
    /// Order of all modules. Only those with a popover section are user-visible in the order list.
    public private(set) var order: [String]
    public private(set) var active: [String: any TUModule] = [:]
    public private(set) var startErrors: [String: String] = [:]
    /// Beta modules are listed and started only while this is on. Their enabled state is kept while hidden.
    public private(set) var showsBeta: Bool

    @ObservationIgnored private let types: [String: any TUModule.Type]
    @ObservationIgnored private let store: ModuleStateStore
    @ObservationIgnored private let popover: PopoverControl
    @ObservationIgnored private var transitioning: Set<String> = []
    @ObservationIgnored private let log = ModuleLog(category: "registry")
    @ObservationIgnored public var leakCheckDelay: Duration = .seconds(2)

    public init(modules: [any TUModule.Type], store: ModuleStateStore, popover: PopoverControl = PopoverControl()) {
        descriptors = modules.map { $0.descriptor }
        types = Dictionary(uniqueKeysWithValues: modules.map { ($0.descriptor.id, $0) })
        self.store = store
        self.popover = popover
        enabledIDs = store.enabledIDs(descriptors: descriptors)
        order = store.order(descriptors: descriptors)
        showsBeta = store.showsBeta
        store.saveEnabled(enabledIDs, descriptors: descriptors)
    }

    public func descriptor(for id: String) -> ModuleDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// Modules shown in Settings: everything except beta modules while beta features are hidden.
    public var visibleDescriptors: [ModuleDescriptor] {
        descriptors.filter(isVisible)
    }

    /// Enabled and visible, i.e. running unless it failed to start.
    public func isEnabled(_ id: String) -> Bool {
        enabledIDs.contains(id) && descriptor(for: id).map(isVisible) == true
    }

    private func isVisible(_ descriptor: ModuleDescriptor) -> Bool {
        showsBeta || !descriptor.isBeta
    }

    /// Active modules in user order.
    public var activeModules: [any TUModule] {
        order.compactMap { active[$0] }
    }

    /// Active modules that contribute a popover section, in user order.
    public var activePopoverModules: [any TUModule] {
        popoverOrder.compactMap { active[$0.id] }
    }

    /// Descriptors of modules that can appear in the popover, in user order.
    public var popoverOrder: [ModuleDescriptor] {
        order.compactMap(descriptor(for:)).filter { $0.hasPopoverSection && isVisible($0) }
    }

    public func startEnabledModules() async {
        for id in order where isEnabled(id) {
            await reconcile(id)
        }
    }

    /// Shows or hides beta modules; hiding stops the running ones, showing restarts those left enabled.
    public func setShowsBeta(_ shows: Bool) async {
        guard shows != showsBeta else { return }
        showsBeta = shows
        store.saveShowsBeta(shows)
        for descriptor in descriptors where descriptor.isBeta {
            await reconcile(descriptor.id)
        }
    }

    public func setEnabled(_ enabled: Bool, for id: String) async {
        guard types[id] != nil else { return }
        if enabled {
            enabledIDs.insert(id)
        } else {
            enabledIDs.remove(id)
        }
        store.saveEnabled(enabledIDs, descriptors: descriptors)
        await reconcile(id)
    }

    public func movePopoverItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        var popoverIDs = popoverOrder.map(\.id)
        popoverIDs.move(fromOffsets: source, toOffset: destination)
        order = popoverIDs + order.filter { !popoverIDs.contains($0) }
        store.saveOrder(order)
    }

    /// Stops every active module (reverse order). Call before the app terminates.
    public func shutdown() async {
        for id in order.reversed() where active[id] != nil {
            await deactivate(id)
        }
    }

    // MARK: - Lifecycle

    /// Drives the module towards its desired state. Toggles that arrive while a transition is in flight are
    /// picked up by the loop of the in-flight call.
    private func reconcile(_ id: String) async {
        guard !transitioning.contains(id) else { return }
        transitioning.insert(id)
        defer { transitioning.remove(id) }

        while isEnabled(id) != (active[id] != nil) {
            if isEnabled(id) {
                guard await activate(id) else { break }
            } else {
                await deactivate(id)
            }
        }
    }

    private func activate(_ id: String) async -> Bool {
        guard let type = types[id] else { return false }
        let context = ModuleContext(
            settings: ModuleSettings(defaults: store.defaults, moduleID: id),
            log: ModuleLog(category: id),
            popover: popover
        )
        let module = type.init(context: context)
        do {
            try await module.start()
        } catch {
            log.logger.error("Failed to start \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            startErrors[id] = error.localizedDescription
            await module.stop()
            return false
        }
        startErrors[id] = nil
        active[id] = module
        for hotkey in module.hotkeys {
            let action = hotkey.action
            KeyboardShortcuts.onKeyUp(for: hotkey.name) {
                MainActor.assumeIsolated { action() }
            }
        }
        log.logger.info("Started \(id, privacy: .public)")
        return true
    }

    private func deactivate(_ id: String) async {
        guard let module = active.removeValue(forKey: id) else { return }
        for hotkey in module.hotkeys {
            KeyboardShortcuts.removeHandler(for: hotkey.name)
        }
        await module.stop()
        log.logger.info("Stopped \(id, privacy: .public)")
        scheduleLeakCheck(module, id: id)
    }

    private func scheduleLeakCheck(_ module: any TUModule, id: String) {
        let delay = leakCheckDelay
        Task { [weak module, weak self] in
            try? await Task.sleep(for: delay)
            guard module != nil else { return }
            self?.log.logger.fault("Module \(id, privacy: .public) is still alive after being disabled")
        }
    }
}
