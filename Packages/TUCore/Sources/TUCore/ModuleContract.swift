import Foundation

/// Checks of the module contract (Docs/MODULES.md) that every module's test target runs:
///
///     @Test @MainActor func followsModuleContract() async {
///         #expect(await ModuleContract.violations(of: ClockModule.self) == [])
///     }
///
/// `start()` is only exercised with `starting: true`, for modules that need no permission or hardware.
@MainActor
public enum ModuleContract {
    public static func violations(of type: any TUModule.Type, starting: Bool = false) async -> [String] {
        let descriptor = type.descriptor
        let id = descriptor.id
        var problems: [String] = []
        if id.range(of: "^[a-z]+$", options: .regularExpression) == nil {
            problems.append("descriptor id \"\(id)\" must be lowercase letters only")
        }

        let suite = "TUModuleContract.\(id).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return problems + ["cannot create test defaults"] }
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = ModuleContext(
            settings: ModuleSettings(defaults: defaults, moduleID: id),
            log: ModuleLog(category: "contract.\(id)"),
            popover: PopoverControl()
        )

        weak var released: (any TUModule)?
        do {
            let module = type.init(context: context)
            released = module
            for hotkey in module.hotkeys where !hotkey.name.rawValue.hasPrefix("\(id).") {
                problems.append("hotkey \"\(hotkey.name.rawValue)\" must be named \"\(id).<name>\"")
            }
            if starting {
                do {
                    try await module.start()
                } catch {
                    problems.append("start() threw: \(error.localizedDescription)")
                }
            }
            // Also covers the registry's cleanup after a failed start: stop() must be safe without start().
            await module.stop()
        }
        // Let cancelled tasks that hold the module weakly finish their current step.
        for _ in 0..<10 { await Task.yield() }
        if released != nil {
            problems.append("instance is still alive after stop() and release (static state, a strong Task or a retain cycle)")
        }

        let prefix = "module.\(id)."
        for key in (defaults.persistentDomain(forName: suite) ?? [:]).keys.sorted() where !key.hasPrefix(prefix) {
            problems.append("settings key \"\(key)\" is outside \"\(prefix)*\" — use ModuleSettings")
        }
        return problems
    }
}
