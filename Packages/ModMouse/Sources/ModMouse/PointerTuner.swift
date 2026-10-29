import Foundation
import IOKit
import IOKit.hid

// Pointer speed/acceleration via IOHIDServiceClient properties, adapted from LinearMouse's PointerKit
// (MIT, © LinearMouse) — https://github.com/linearmouse/linearmouse

/// Applies pointer speed and acceleration to external mice and restores the original values on `restore()`.
/// Speed maps to `HIDPointerResolution` (lower = faster) exactly like LinearMouse, so its settings carry over.
@MainActor
final class PointerTuner {
    struct Settings: Equatable {
        /// 0…1, LinearMouse scale.
        var speed: Double
        /// 0…3 (system slider range), written to `HIDMouseAcceleration`.
        var acceleration: Double
    }

    /// What `apply` did to one device, shown in settings so "nothing changes" reports can be told apart.
    struct DeviceStatus: Equatable, Identifiable {
        let id: UInt64
        let name: String
        let applied: Bool
    }

    private struct Original {
        let resolution: Double?
        let accelerationKey: String
        let acceleration: Double?
    }

    static let resolutionKey = "HIDPointerResolution"
    nonisolated static let mouseAccelerationKey = "HIDMouseAcceleration"
    nonisolated static let pointerAccelerationKey = "HIDPointerAcceleration"
    nonisolated static let trackpadAccelerationKey = "HIDTrackpadAcceleration"
    static let accelerationTypeKey = "HIDPointerAccelerationType"
    /// Resolution macOS uses for mice when the property is absent.
    static let defaultResolution = 400.0
    private nonisolated static let speedRange = 1.0 / 1200 ... 1.0 / 40

    /// Created on first use. It is never scheduled, so its service list goes stale when a mouse is re-enumerated
    /// (receiver replugged): writes then go to the removed service and fail (#23 follow-up). `resetClient()`
    /// drops it so the next apply sees the current devices.
    private var client: IOHIDEventSystemClient?
    private var originals: [UInt64: Original] = [:]
    private var deviceWatcher: IOHIDManager?

    /// Call when mice were attached or re-enumerated.
    func resetClient() {
        client = nil
    }

    nonisolated static func resolution(forSpeed speed: Double) -> Double {
        let clamped = min(1, max(0, speed))
        return 1 / (speedRange.lowerBound + clamped * (speedRange.upperBound - speedRange.lowerBound))
    }

    /// Which acceleration property a pointing device uses, like LinearMouse: the type it reports, else a guess.
    /// Trackpads (nil) are left to the system.
    nonisolated static func accelerationKey(reportedType: String?, hasPointerAcceleration: Bool) -> String? {
        if let reportedType { return reportedType == trackpadAccelerationKey ? nil : reportedType }
        return hasPointerAcceleration ? pointerAccelerationKey : mouseAccelerationKey
    }

    /// Applies to every mouse currently connected (trackpads are skipped) and reports what took effect.
    @discardableResult
    func apply(_ settings: Settings) -> [DeviceStatus] {
        let resolution = Self.resolution(forSpeed: settings.speed).clamped(10, 1995)
        return mouseServices().compactMap { service, accelerationKey in
            guard let id = IOHIDServiceClientGetRegistryID(service) as? UInt64 else { return nil }
            if originals[id] == nil {
                originals[id] = Original(
                    resolution: Self.fixed(service, Self.resolutionKey),
                    accelerationKey: accelerationKey,
                    acceleration: Self.fixed(service, accelerationKey)
                )
            }
            // Resolution takes effect when acceleration is written after it (LinearMouse does the same).
            let wroteResolution = Self.setFixed(service, Self.resolutionKey, resolution)
            let wroteAcceleration = Self.setFixed(service, accelerationKey, settings.acceleration.clamped(0, 40))
            let readBack = Self.fixed(service, Self.resolutionKey)
            let applied = wroteResolution && wroteAcceleration && (readBack.map { abs($0 - resolution) < 1 } ?? true)
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? "마우스"
            return DeviceStatus(id: id, name: name, applied: applied)
        }
    }

    func restore() {
        for (service, _) in mouseServices() {
            guard let id = IOHIDServiceClientGetRegistryID(service) as? UInt64, let original = originals[id] else { continue }
            Self.setFixed(service, Self.resolutionKey, original.resolution ?? Self.defaultResolution)
            if let acceleration = original.acceleration {
                Self.setFixed(service, original.accelerationKey, acceleration)
            }
        }
        originals.removeAll()
        client = nil
    }

    /// Calls `onChange` (debounced by the caller) when mice are attached, e.g. receiver plugged in or wake from sleep.
    func watchDevices(_ onChange: @escaping @MainActor () -> Void) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse,
        ] as CFDictionary)
        let box = Unmanaged.passRetained(CallbackBox(onChange)).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let callback = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue().callback
            MainActor.assumeIsolated { callback() }
        }, box)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        deviceWatcher = manager
        watcherContext = box
    }

    private var watcherContext: UnsafeMutableRawPointer?

    func stopWatching() {
        if let deviceWatcher {
            IOHIDManagerUnscheduleFromRunLoop(deviceWatcher, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerRegisterDeviceMatchingCallback(deviceWatcher, nil, nil)
        }
        if let watcherContext {
            Unmanaged<CallbackBox>.fromOpaque(watcherContext).release()
        }
        deviceWatcher = nil
        watcherContext = nil
    }

    /// Mice and other pointers with the acceleration property each one uses. Matching only devices that report
    /// `HIDMouseAcceleration` silently skipped mice that report another type or none (#23).
    private func mouseServices() -> [(IOHIDServiceClient, String)] {
        let client = client ?? Self.makeAdminClient() ?? IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        self.client = client
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.compactMap { service in
            let page = UInt32(kHIDPage_GenericDesktop)
            guard IOHIDServiceClientConformsTo(service, page, UInt32(kHIDUsage_GD_Mouse)) != 0
                || IOHIDServiceClientConformsTo(service, page, UInt32(kHIDUsage_GD_Pointer)) != 0 else { return nil }
            let key = Self.accelerationKey(
                reportedType: IOHIDServiceClientCopyProperty(service, Self.accelerationTypeKey as CFString) as? String,
                hasPointerAcceleration: Self.fixed(service, Self.pointerAccelerationKey) != nil
            )
            return key.map { (service, $0) }
        }
    }

    /// The public "simple" client can set acceleration but not resolution; LinearMouse uses this private admin client.
    private static func makeAdminClient() -> IOHIDEventSystemClient? {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let symbol = dlsym(handle, "IOHIDEventSystemClientCreate") else { return nil }
        return unsafeBitCast(symbol, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
    }

    private static func fixed(_ service: IOHIDServiceClient, _ key: String) -> Double? {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? Int).map { Double($0) / 65536 }
    }

    @discardableResult
    private static func setFixed(_ service: IOHIDServiceClient, _ key: String, _ value: Double) -> Bool {
        IOHIDServiceClientSetProperty(service, key as CFString, Int(value * 65536) as CFNumber)
    }
}

final class CallbackBox {
    let callback: @MainActor () -> Void
    init(_ callback: @escaping @MainActor () -> Void) { self.callback = callback }
}

extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double { Swift.min(upper, Swift.max(lower, self)) }
}
