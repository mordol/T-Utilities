import ClamshellKit
import Foundation
import IOKit.ps

/// Records that this app disabled lid-closed sleep, so a later launch restores it only if a previous
/// run died before doing so (an unconditional restore can make the system blank displays).
struct ClamshellMarker {
    static let key = "awakeClamshellSleepDisabled"

    private let defaults: UserDefaults

    // module-rules: allow crash-recovery marker read at launch before any module state; key predates namespacing
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isSet: Bool {
        defaults.bool(forKey: Self.key)
    }

    func set() {
        defaults.set(true, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    /// Startup crash recovery: restores lid-closed sleep only if the marker is set, then clears it.
    /// - Returns: whether a restore was attempted.
    @discardableResult
    func recoverIfNeeded(restore: () -> Bool = { Clamshell.setSleepDisabled(false) }) -> Bool {
        guard isSet else { return false }
        _ = restore()
        clear()
        return true
    }
}

/// Keeps the Mac awake with the lid closed while active.
///
/// The clamshell setting outlives this process, so a helper (`AwakeGuard`) is spawned with a heartbeat
/// pipe: if the app dies or hangs, the helper restores lid-closed sleep. If the helper dies, `isActive`
/// turns false and the module's next tick re-activates.
@MainActor
final class LidSleepGuard {
    static let heartbeatInterval: Duration = .seconds(10)

    private let helperURL: URL?
    private let marker = ClamshellMarker()
    private var helper: Process?
    private var heartbeatPipe: Pipe?
    private var heartbeat: Task<Void, Never>?

    init(helperURL: URL? = Bundle.main.url(forAuxiliaryExecutable: "AwakeGuard")) {
        self.helperURL = helperURL
    }

    var isActive: Bool {
        helper?.isRunning == true
    }

    var isAvailable: Bool {
        helperURL != nil
    }

    /// Spawns the fail-safe helper first, then disables lid-closed sleep.
    @discardableResult
    func activate() -> Bool {
        if isActive { return true }
        deactivate()
        guard let helperURL else { return false }

        let pipe = Pipe()
        // Writing to a pipe whose reader died must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let process = Process()
        process.executableURL = helperURL
        process.standardInput = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        helper = process
        heartbeatPipe = pipe
        heartbeat = Task { [weak pipe] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let pipe, (try? pipe.fileHandleForWriting.write(contentsOf: [0x2E])) != nil else { return }
            }
        }
        marker.set()
        return Clamshell.setSleepDisabled(true)
    }

    /// Restores lid-closed sleep and lets the helper exit (EOF on its pipe).
    func deactivate() {
        if helper != nil || heartbeatPipe != nil {
            if Clamshell.setSleepDisabled(false) { marker.clear() }
        }
        heartbeat?.cancel()
        heartbeat = nil
        try? heartbeatPipe?.fileHandleForWriting.close()
        heartbeatPipe = nil
        helper = nil
    }
}

/// Safety conditions that release all sleep prevention (lid closed in a bag = poor cooling).
enum PowerGuard {
    struct Snapshot: Equatable {
        var onBattery: Bool
        var batteryPercent: Int?
        var thermal: ProcessInfo.ThermalState
    }

    /// - Returns: why prevention must stop, or nil.
    static func tripReason(_ snapshot: Snapshot, batteryThreshold: Int, thermalGuard: Bool) -> String? {
        if snapshot.onBattery, batteryThreshold > 0, let percent = snapshot.batteryPercent, percent <= batteryThreshold {
            return "배터리 \(batteryThreshold)% 이하"
        }
        if thermalGuard, snapshot.thermal == .serious || snapshot.thermal == .critical {
            return "기기 과열"
        }
        return nil
    }

    static func current() -> Snapshot {
        var snapshot = Snapshot(onBattery: false, batteryPercent: nil, thermal: ProcessInfo.processInfo.thermalState)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return snapshot }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            snapshot.onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                snapshot.batteryPercent = current * 100 / max
            }
        }
        return snapshot
    }
}
