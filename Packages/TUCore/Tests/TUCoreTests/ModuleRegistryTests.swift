import Foundation
import SwiftUI
import Testing
@testable import TUCore

@MainActor
@Observable
final class AlphaModule: TUModule {
    static let descriptor = ModuleDescriptor(id: "alpha", displayName: "Alpha", symbol: "a.circle", hasPopoverSection: true)
    static var instances = 0
    var started = false

    init(context: ModuleContext) { Self.instances += 1 }
    deinit { MainActor.assumeIsolated { Self.instances -= 1 } }

    func start() async throws { started = true }
    func stop() async { started = false }
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
@Observable
final class BetaModule: TUModule {
    static let descriptor = ModuleDescriptor(id: "beta", displayName: "Beta", symbol: "b.circle", hasPopoverSection: true, enabledByDefault: false)

    init(context: ModuleContext) {}
    func start() async throws {}
    func stop() async {}
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
@Observable
final class HiddenModule: TUModule {
    static let descriptor = ModuleDescriptor(id: "hidden", displayName: "Hidden", symbol: "eye.slash")

    init(context: ModuleContext) {}
    func start() async throws {}
    func stop() async {}
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
@Observable
final class FailingModule: TUModule {
    struct Failure: Error {}
    static let descriptor = ModuleDescriptor(id: "failing", displayName: "Failing", symbol: "xmark")

    init(context: ModuleContext) {}
    func start() async throws { throw Failure() }
    func stop() async {}
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
@Observable
final class ExperimentModule: TUModule {
    static let descriptor = ModuleDescriptor(id: "experiment", displayName: "Experiment", symbol: "flask", hasPopoverSection: true, isBeta: true)

    init(context: ModuleContext) {}
    func start() async throws {}
    func stop() async {}
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
@Suite(.serialized)
struct ModuleRegistryTests {
    let defaults: UserDefaults

    init() {
        let suite = "TUCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func makeRegistry() -> ModuleRegistry {
        ModuleRegistry(
            modules: [AlphaModule.self, BetaModule.self, HiddenModule.self, FailingModule.self],
            store: ModuleStateStore(defaults: defaults)
        )
    }

    @Test func startsOnlyModulesEnabledByDefault() async {
        let registry = makeRegistry()
        await registry.startEnabledModules()
        #expect(registry.active["alpha"] != nil)
        #expect(registry.active["hidden"] != nil)
        #expect(registry.active["beta"] == nil)
        await registry.shutdown()
    }

    @Test func disablingReleasesTheInstance() async throws {
        let registry = makeRegistry()
        await registry.startEnabledModules()
        weak var alpha = registry.active["alpha"]
        #expect(alpha != nil)

        await registry.setEnabled(false, for: "alpha")
        #expect(registry.active["alpha"] == nil)
        #expect(alpha == nil)
        #expect(AlphaModule.instances == 0)
        await registry.shutdown()
    }

    @Test func enabledStateAndOrderPersist() async {
        let registry = makeRegistry()
        await registry.setEnabled(true, for: "beta")
        await registry.setEnabled(false, for: "alpha")
        registry.movePopoverItems(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        await registry.shutdown()

        let reloaded = makeRegistry()
        #expect(reloaded.enabledIDs.contains("beta"))
        #expect(!reloaded.enabledIDs.contains("alpha"))
        #expect(reloaded.popoverOrder.map(\.id) == ["beta", "alpha"])
    }

    @Test func popoverOrderExcludesModulesWithoutSection() {
        let registry = makeRegistry()
        #expect(registry.popoverOrder.map(\.id) == ["alpha", "beta"])
    }

    @Test func startFailureIsRecordedAndModuleStaysInactive() async {
        let registry = makeRegistry()
        await registry.startEnabledModules()
        #expect(registry.active["failing"] == nil)
        #expect(registry.startErrors["failing"] != nil)
        #expect(registry.isEnabled("failing"))
        await registry.shutdown()
    }

    @Test func storeAppendsNewModulesToSavedOrder() {
        defaults.set(["beta", "unknown"], forKey: ModuleStateStore.orderKey)
        let store = ModuleStateStore(defaults: defaults)
        let order = store.order(descriptors: [AlphaModule.descriptor, BetaModule.descriptor])
        #expect(order == ["beta", "alpha"])
    }

    @Test func newlyAddedModuleGetsDefaultButUserChoiceSticks() async {
        let store = ModuleStateStore(defaults: defaults)
        let older = ModuleRegistry(modules: [BetaModule.self], store: store)
        await older.setEnabled(false, for: "beta")

        // A later version adds Alpha (enabled by default). It starts enabled; Beta stays off.
        let newer = ModuleRegistry(modules: [AlphaModule.self, BetaModule.self], store: store)
        #expect(newer.enabledIDs == ["alpha"])

        // Once known, disabling Alpha is respected on the next launch.
        await newer.setEnabled(false, for: "alpha")
        let relaunched = ModuleRegistry(modules: [AlphaModule.self, BetaModule.self], store: store)
        #expect(relaunched.enabledIDs.isEmpty)
    }

    @Test func betaModulesRunOnlyWhileShown() async {
        let store = ModuleStateStore(defaults: defaults)
        let registry = ModuleRegistry(modules: [AlphaModule.self, ExperimentModule.self], store: store)
        await registry.startEnabledModules()
        #expect(registry.active["experiment"] == nil)
        #expect(!registry.isEnabled("experiment"))
        #expect(registry.visibleDescriptors.map(\.id) == ["alpha"])
        #expect(registry.popoverOrder.map(\.id) == ["alpha"])

        await registry.setShowsBeta(true)
        #expect(registry.active["experiment"] != nil)
        #expect(registry.popoverOrder.map(\.id) == ["alpha", "experiment"])
        #expect(ModuleRegistry(modules: [ExperimentModule.self], store: store).showsBeta)

        await registry.setShowsBeta(false)
        #expect(registry.active["experiment"] == nil)
        // Hiding keeps the user's choice; showing again restarts it.
        await registry.setShowsBeta(true)
        #expect(registry.active["experiment"] != nil)
        await registry.shutdown()
    }

    @Test func moduleSettingsAreNamespaced() {
        let settings = ModuleSettings(defaults: defaults, moduleID: "alpha")
        settings.set(42, for: "speed")
        #expect(defaults.integer(forKey: "module.alpha.speed") == 42)
        #expect(settings.value("speed", default: 0) == 42)
        #expect(settings.value("missing", default: 7) == 7)
    }
}
