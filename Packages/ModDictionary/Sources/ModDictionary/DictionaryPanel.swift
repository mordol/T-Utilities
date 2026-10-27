import AppKit
import TUCore
import WebKit

/// Borderless floating panel that can take keyboard focus and handles ESC / ⌘1 / ⌘2 itself,
/// because the web view would otherwise swallow them.
final class DictionaryPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onSelectSite: ((DictionarySite) -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53, !isComposingText {
                onEscape?()
                return
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               let key = event.charactersIgnoringModifiers, let site = DictionarySite(shortcutKey: key) {
                onSelectSite?(site)
                return
            }
        }
        super.sendEvent(event)
    }

    /// ESC while composing Korean should cancel the composition, not close the panel.
    private var isComposingText: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}

/// Owns the panel and its web view. Both exist only while the panel is shown, so the WebKit
/// content processes go away as soon as it closes.
@MainActor
final class DictionaryPanelController: NSObject, WKUIDelegate {
    private static let defaultSize = NSSize(width: 480, height: 700)
    private static let resizeGrabMargin: CGFloat = 8
    private static let minSize = NSSize(width: 360, height: 400)
    /// Settings names, stored as `module.dictionary.<name>`.
    static let widthKey = "panelWidth"
    static let heightKey = "panelHeight"
    static let centerOffsetKey = "panelCenterOffset"
    static let topGapKey = "panelTopGap"
    private static let defaultTopGap: CGFloat = 8

    private var panel: DictionaryPanel?
    private var webView: WKWebView?
    private var resignObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?

    private let settings: ModuleSettings
    private let currentSite: () -> DictionarySite
    private let selectSite: (DictionarySite) -> Void

    init(
        settings: ModuleSettings,
        currentSite: @escaping () -> DictionarySite,
        selectSite: @escaping (DictionarySite) -> Void
    ) {
        self.settings = settings
        self.currentSite = currentSite
        self.selectSite = selectSite
    }

    var isShown: Bool { panel != nil }

    func toggle() {
        isShown ? close() : show()
    }

    func show() {
        guard panel == nil else { return }
        let area = Self.screenUnderMouse()?.visibleFrame ?? .zero
        let frame = savedFrame(in: area)
        let webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: WKWebViewConfiguration())
        webView.uiDelegate = self
        webView.load(URLRequest(url: currentSite().url))

        let panel = DictionaryPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.minSize = Self.minSize
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in self?.close() }
        panel.onSelectSite = { [weak self] site in self?.switchTo(site) }

        webView.autoresizingMask = [.width, .height]
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 12
        webView.layer?.masksToBounds = true
        panel.contentView = webView

        // Clicking outside (focus moves elsewhere) closes the panel, like allkdic.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                // Grabbing the panel's edge to resize it also resigns key; that is not an outside click.
                if let panel, NSEvent.pressedMouseButtons != 0,
                   panel.frame.insetBy(dx: -Self.resizeGrabMargin, dy: -Self.resizeGrabMargin).contains(NSEvent.mouseLocation) {
                    return
                }
                self?.close()
            }
        }

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                self.saveFrame(panel.frame, in: panel.screen?.visibleFrame ?? panel.frame)
                // The edge grab took key away; take it back so Esc and the outside-click close keep working.
                panel.makeKey()
            }
        }

        self.panel = panel
        self.webView = webView
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        webView?.stopLoading()
        webView?.uiDelegate = nil
        panel?.onEscape = nil
        panel?.onSelectSite = nil
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel?.close()
        // Dropping the last references deallocates the WKWebView, which ends its web content process.
        webView = nil
        panel = nil
    }

    private func switchTo(_ site: DictionarySite) {
        selectSite(site)
        webView?.load(URLRequest(url: site.url))
    }

    /// Resizing from the left/top edge moves the panel too, so the place is kept relative to the screen
    /// (offset from its center, gap below the menu bar) and reapplied on whichever screen the mouse is on.
    private func saveFrame(_ frame: NSRect, in area: NSRect) {
        settings.set(Double(frame.width), for: Self.widthKey)
        settings.set(Double(frame.height), for: Self.heightKey)
        settings.set(Double(frame.midX - area.midX), for: Self.centerOffsetKey)
        settings.set(Double(area.maxY - frame.maxY), for: Self.topGapKey)
    }

    /// The last size and place, or the default (centered just below the menu bar).
    private func savedFrame(in area: NSRect) -> NSRect {
        let width: Double = settings.value(Self.widthKey, default: 0)
        let height: Double = settings.value(Self.heightKey, default: 0)
        let size = width > 0 && height > 0 ? NSSize(width: width, height: height) : Self.defaultSize
        let topGap: Double = settings.value(Self.topGapKey, default: Self.defaultTopGap)
        let centerOffset: Double = settings.value(Self.centerOffsetKey, default: 0)
        return Self.frame(size: size, centerOffset: centerOffset, topGap: topGap, in: area)
    }

    /// Places `size` relative to `area`, then keeps it inside: shrinks to fit (not below `minSize`) and slides back in.
    static func frame(size: NSSize, centerOffset: CGFloat, topGap: CGFloat, in area: NSRect) -> NSRect {
        let width = max(min(size.width, area.width), minSize.width)
        let height = max(min(size.height, area.height), minSize.height)
        var x = area.midX + centerOffset - width / 2
        var y = area.maxY - topGap - height
        x = min(max(x, area.minX), area.maxX - width)
        y = min(max(y, area.minY), area.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    // MARK: - WKUIDelegate

    /// target=_blank links open in the default browser instead of a second web view.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            close()
        }
        return nil
    }
}
