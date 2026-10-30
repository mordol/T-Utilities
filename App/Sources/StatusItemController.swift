import AppKit
import SwiftUI
import TUCore
import TUUI

/// The single menu bar item: main icon (overridable by a module, e.g. Awake) + accessory text (e.g. Clock).
/// Left click toggles the popover, right click shows the quick menu.
@MainActor
final class StatusItemController: NSObject {
    private let registry: ModuleRegistry
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var keyDownMonitor: Any?
    private var outsideClickMonitors: [Any] = []
    /// App that was frontmost before the popover activated us; gets focus back when the popover closes.
    private var previousApp: NSRunningApplication?

    init(registry: ModuleRegistry, updater: Updater, popoverControl: PopoverControl, openSettings: @escaping () -> Void) {
        self.registry = registry
        self.openSettings = openSettings
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView(registry: registry, updater: updater) { [weak self] in
            self?.popover.performClose(nil)
            openSettings()
        })
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        popoverControl.isShown = { [weak self] in self?.popover.isShown ?? false }
        popoverControl.show = { [weak self] in self?.showPopover() }
        popoverControl.close = { [weak self] in self?.popover.performClose(nil) }
        installKeyDownMonitor()
        installOutsideClickMonitors()
        observeAppearance()
    }

    private func observeAppearance() {
        withObservationTracking {
            updateAppearance()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAppearance() }
        }
    }

    private func updateAppearance() {
        guard let button = statusItem.button else { return }
        let modules = registry.activeModules
        let defaultImage = GridIcon.image()
        defaultImage.accessibilityDescription = "T-Utilities"
        button.image = modules.lazy.compactMap(\.statusItemImage).first ?? defaultImage

        let text = modules.compactMap(\.statusItemText).joined(separator: "  ")
        button.title = text.isEmpty ? "" : " \(text)"
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        for module in registry.activePopoverModules {
            module.popoverWillShow()
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        fitListHeightToScreen()
    }

    /// A list height saved on a taller display can push the popover past the bottom of this one; shrink it to fit.
    private func fitListHeightToScreen() {
        guard let window = popover.contentViewController?.view.window, let screen = window.screen else { return }
        let overflow = screen.visibleFrame.minY + 8 - window.frame.minY
        guard overflow > 0 else { return }
        let defaults = UserDefaults.standard
        let current = defaults.object(forKey: PopoverSize.listHeightKey) as? Double ?? Double(PopoverSize.defaultListHeight)
        defaults.set(max(Double(PopoverSize.listHeightRange.lowerBound), current - overflow), forKey: PopoverSize.listHeightKey)
    }

    /// While the popover is shown, key events go to modules in popover order; unhandled Esc closes it.
    private func installKeyDownMonitor() {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.window == self.popover.contentViewController?.view.window else {
                return event
            }
            for module in self.registry.activePopoverModules where module.handlePopoverKeyDown(event) {
                return nil
            }
            if event.keyCode == 53 { // Esc
                self.popover.performClose(nil)
                return nil
            }
            return event
        }
    }

    /// Closes the popover on a click outside it. `.transient` alone stops doing so after a module's
    /// `NSMenu.popUp` (e.g. Cable) has run inside the popover, leaving only the status item to close it.
    private func installOutsideClickMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let closeIfOutside = { [weak self] in
            guard let self, self.popover.isShown,
                  let popoverFrame = self.popover.contentViewController?.view.window?.frame,
                  let button = self.statusItem.button, let buttonWindow = button.window else { return }
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if PopoverDismissal.shouldClose(click: NSEvent.mouseLocation, popoverFrame: popoverFrame, statusButtonFrame: buttonFrame) {
                self.popover.performClose(nil)
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated(closeIfOutside)
        }) {
            outsideClickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            closeIfOutside()
            return event
        }) {
            outsideClickMonitors.append(local)
        }
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        for module in registry.activeModules {
            let items = module.makeQuickMenuItems()
            guard !items.isEmpty else { continue }
            items.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        let settings = NSMenuItem(title: "설정…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "T-Utilities 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Attach temporarily so the left click keeps opening the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenSettings() {
        openSettings()
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        for module in registry.activePopoverModules {
            module.popoverDidClose()
        }
        // Next turn, so a window opened from the popover (Settings, an alert) is already up.
        let app = previousApp
        previousApp = nil
        DispatchQueue.main.async { Self.returnFocus(to: app) }
    }

    /// Showing the popover activated this window-less app; without this, focus stays here after it closes
    /// and keystrokes go nowhere (#25). Leaves focus alone when the user already moved on to another app or
    /// one of our own windows is open.
    private static func returnFocus(to app: NSRunningApplication?) {
        guard let app, !app.isTerminated, NSApp.isActive, NSApp.keyWindow == nil, NSApp.modalWindow == nil else { return }
        app.activate()
    }
}
