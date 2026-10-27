import Foundation
import KeyboardShortcuts
import SwiftUI
import Testing
@testable import TUCore

@MainActor
@Observable
final class StrayKeysModule: TUModule {
    static let descriptor = ModuleDescriptor(id: "stray", displayName: "Stray", symbol: "key")
    static let toggle = KeyboardShortcuts.Name("strayToggle")

    init(context: ModuleContext) {
        context.settings.defaults.set(1, forKey: "strayRawKey")
        context.settings.set(1, for: "fine")
    }
    func start() async throws {}
    func stop() async {}
    var hotkeys: [HotkeyDefinition] { [HotkeyDefinition(name: Self.toggle, title: "Toggle") {}] }
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
@Observable
final class StrongLoopModule: TUModule {
    static let descriptor = ModuleDescriptor(id: "strongloop", displayName: "Loop", symbol: "repeat")
    private var loop: Task<Void, Never>?

    init(context: ModuleContext) {}
    func start() async throws {
        loop = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)); self.tick() } }
    }
    func stop() async {} // forgets loop?.cancel()
    private func tick() {}
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
struct ModuleContractTests {
    @Test func cleanModulePasses() async {
        #expect(await ModuleContract.violations(of: AlphaModule.self, starting: true) == [])
    }

    @Test func reportsKeysOutsideNamespaceAndHotkeyNames() async {
        let problems = await ModuleContract.violations(of: StrayKeysModule.self)
        #expect(problems.count == 2)
        #expect(problems.contains { $0.contains("strayRawKey") })
        #expect(problems.contains { $0.contains("strayToggle") })
    }

    @Test func reportsInstanceKeptAliveAfterStop() async {
        let problems = await ModuleContract.violations(of: StrongLoopModule.self, starting: true)
        #expect(problems.contains { $0.contains("still alive") })
    }
}

@MainActor
struct LegacyKeyMigrationTests {
    @Test func movesLegacyValueOnceWithoutOverwriting() {
        let suite = "TUCoreTests.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ModuleSettings(defaults: defaults, moduleID: "dictionary")

        defaults.set(500.0, forKey: "dictionary.panelWidth")
        settings.migrateLegacyKey("dictionary.panelWidth", to: "panelWidth")
        #expect(settings.value("panelWidth", default: 0.0) as Double == 500)
        #expect(defaults.object(forKey: "dictionary.panelWidth") == nil)

        // A newer value already saved under the namespace wins.
        defaults.set(300.0, forKey: "dictionary.panelWidth")
        settings.migrateLegacyKey("dictionary.panelWidth", to: "panelWidth")
        #expect(settings.value("panelWidth", default: 0.0) as Double == 500)
        #expect(defaults.object(forKey: "dictionary.panelWidth") == nil)
    }
}
