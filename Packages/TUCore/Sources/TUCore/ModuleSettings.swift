import Foundation
import os

/// Per-module settings namespace: keys are stored as `module.<id>.<key>`.
@MainActor
public struct ModuleSettings {
    public let defaults: UserDefaults
    public let moduleID: String

    public init(defaults: UserDefaults, moduleID: String) {
        self.defaults = defaults
        self.moduleID = moduleID
    }

    public func key(_ name: String) -> String { "module.\(moduleID).\(name)" }

    public func value<T>(_ name: String, default fallback: T) -> T {
        defaults.object(forKey: key(name)) as? T ?? fallback
    }

    public func set(_ value: Any?, for name: String) {
        defaults.set(value, forKey: key(name))
    }

    /// Moves a value saved by an older version under a key outside the namespace, once.
    public func migrateLegacyKey(_ legacyKey: String, to name: String) {
        guard let value = defaults.object(forKey: legacyKey) else { return }
        if defaults.object(forKey: key(name)) == nil { defaults.set(value, forKey: key(name)) }
        defaults.removeObject(forKey: legacyKey)
    }
}

public struct ModuleLog: Sendable {
    public let logger: Logger

    public init(category: String) {
        logger = Logger(subsystem: "com.taegyu.tutilities", category: category)
    }
}

/// Persists which modules are enabled and the popover order.
@MainActor
public struct ModuleStateStore {
    static let enabledKey = "modules.enabled"
    static let orderKey = "modules.order"
    /// Modules the user has seen; modules added in later versions get their default enabled state.
    static let knownKey = "modules.known"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func enabledIDs(descriptors: [ModuleDescriptor]) -> Set<String> {
        let saved = Set(defaults.stringArray(forKey: Self.enabledKey) ?? [])
        let known = Set(defaults.stringArray(forKey: Self.knownKey) ?? [])
        let newDefaults = descriptors.filter { $0.enabledByDefault && !known.contains($0.id) }.map(\.id)
        return saved.union(newDefaults)
    }

    public func saveEnabled(_ ids: Set<String>, descriptors: [ModuleDescriptor]) {
        defaults.set(ids.sorted(), forKey: Self.enabledKey)
        let known = Set(defaults.stringArray(forKey: Self.knownKey) ?? []).union(descriptors.map(\.id))
        defaults.set(known.sorted(), forKey: Self.knownKey)
    }

    /// Saved order, with unknown IDs dropped and newly added modules appended in registration order.
    public func order(descriptors: [ModuleDescriptor]) -> [String] {
        let known = descriptors.map(\.id)
        let saved = (defaults.stringArray(forKey: Self.orderKey) ?? []).filter(known.contains)
        return saved + known.filter { !saved.contains($0) }
    }

    public func saveOrder(_ ids: [String]) {
        defaults.set(ids, forKey: Self.orderKey)
    }
}
