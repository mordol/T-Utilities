import AppKit
import ApplicationServices

/// A window of a regular app, as listed in the switcher.
struct SwitcherWindow: Identifiable {
    let id: Int
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let title: String
    let isMinimized: Bool
    /// Present for on-screen windows that were matched with the CGWindowList; used to capture the thumbnail.
    let windowID: CGWindowID?
    let element: AXUIElement
}

/// Lists the windows of the current Space (plus minimized ones) through the Accessibility API and focuses one.
/// All Accessibility calls are synchronous round trips to the target app, so this only runs on demand.
@MainActor
enum SwitcherWindows {
    /// Per-app Accessibility timeout, so one hung app cannot hold up the switcher.
    private static let messagingTimeout: Float = 0.3

    static func current() -> [SwitcherWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [(app: NSRunningApplication, element: AXUIElement, snapshot: WindowSnapshot)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID && !app.isTerminated {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
            for element in appElement.attribute(kAXWindowsAttribute) as [AXUIElement]? ?? [] {
                guard (element.attribute(kAXRoleAttribute) as String?) == kAXWindowRole as String,
                      (element.attribute(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole as String,
                      let frame = element.frame else { continue }
                let snapshot = WindowSnapshot(
                    pid: app.processIdentifier,
                    title: element.attribute(kAXTitleAttribute) ?? "",
                    frame: frame,
                    isMinimized: (element.attribute(kAXMinimizedAttribute) as Bool?) ?? false
                )
                found.append((app, element, snapshot))
            }
        }

        let candidates = onScreenCandidates()
        let matches = SwitcherLogic.match(found.map(\.snapshot), to: candidates)
        let zOrder = matches.map { match in match.flatMap { match in candidates.firstIndex { $0.windowID == match.windowID } } }
        let order = SwitcherLogic.displayOrder(zOrder: zOrder, isMinimized: found.map(\.snapshot.isMinimized))
        return order.enumerated().map { position, index in
            let entry = found[index]
            return SwitcherWindow(
                id: position, pid: entry.app.processIdentifier,
                appName: entry.app.localizedName ?? "", icon: entry.app.icon,
                title: entry.snapshot.title, isMinimized: entry.snapshot.isMinimized,
                windowID: matches[index]?.windowID, element: entry.element
            )
        }
    }

    /// Unminimizes, raises and activates. Activation goes through Accessibility first because a menu bar app
    /// is not frontmost, and `NSRunningApplication.activate` alone can be ignored then.
    static func focus(_ window: SwitcherWindow) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    /// Presses the window's close button, like clicking it. Returns whether the press went through; the app
    /// may still keep the window open (e.g. to ask about unsaved changes).
    static func close(_ window: SwitcherWindow) -> Bool {
        guard let button: AXUIElement = window.element.attribute(kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// On-screen normal-layer windows, front to back.
    private static func onScreenCandidates() -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return WindowCandidate(windowID: id, pid: pid, title: info[kCGWindowName as String] as? String ?? "", frame: frame)
        }
    }
}

private extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var frame: CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position: AXValue = attribute(kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
              let extent: AXValue = attribute(kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
