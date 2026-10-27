import AppKit
import KeyboardShortcuts
import SwiftUI
import TUCore

// Idea from allkdic (MIT, © Suyeol Jeon) — https://github.com/devxoul/allkdic. Fresh implementation.

extension KeyboardShortcuts.Name {
    static let dictionaryToggle = Self("dictionary.toggle", initial: .init(.space, modifiers: [.option, .command]))
}

/// Dictionary panel (Naver / Daum) toggled with a global hotkey.
@MainActor
@Observable
public final class DictionaryModule: TUModule {
    public static let descriptor = ModuleDescriptor(
        id: "dictionary",
        displayName: "Dictionary",
        symbol: "character.book.closed",
        enabledByDefault: false
    )

    /// ⌥⌘Space is macOS' default "Show Finder search window" shortcut.
    static let hotkeyConflicts: [KeyboardShortcuts.Shortcut: String] = [
        .init(.space, modifiers: [.option, .command]):
            "macOS의 'Finder 검색 윈도우 보기'(⌥⌘Space)와 같은 키입니다. 시스템 설정 > 키보드 > 키보드 단축키 > Spotlight에서 해제하거나 다른 키로 바꾸세요.",
    ]

    @ObservationIgnored private let settings: ModuleSettings
    @ObservationIgnored private var panelController: DictionaryPanelController?

    /// Dictionary shown when the panel opens. Switching with ⌘1/⌘2 in the panel updates it too.
    var site: DictionarySite {
        didSet { settings.set(site.rawValue, for: "site") }
    }

    public init(context: ModuleContext) {
        settings = context.settings
        site = DictionarySite(rawValue: context.settings.value("site", default: DictionarySite.naver.rawValue)) ?? .naver
    }

    public func start() async throws {
        // v0.1.6–v0.1.9 saved the panel frame outside the module namespace.
        for name in [DictionaryPanelController.widthKey, DictionaryPanelController.heightKey,
                     DictionaryPanelController.centerOffsetKey, DictionaryPanelController.topGapKey] {
            settings.migrateLegacyKey("dictionary.\(name)", to: name)
        }
        panelController = DictionaryPanelController(
            settings: settings,
            currentSite: { [weak self] in self?.site ?? .naver },
            selectSite: { [weak self] in self?.site = $0 }
        )
    }

    public func stop() async {
        panelController?.close()
        panelController = nil
    }

    public var hotkeys: [HotkeyDefinition] {
        [
            HotkeyDefinition(name: .dictionaryToggle, title: "사전 열기/닫기", conflicts: Self.hotkeyConflicts) { [weak self] in
                self?.panelController?.toggle()
            },
        ]
    }

    public func makeQuickMenuItems() -> [NSMenuItem] {
        [ClosureMenuItem("사전 열기") { [weak self] in self?.panelController?.show() }]
    }

    public func makeSettingsView() -> AnyView {
        AnyView(DictionarySettingsView(module: self))
    }
}

private struct DictionarySettingsView: View {
    @Bindable var module: DictionaryModule

    var body: some View {
        Form {
            Section("사전") {
                Picker("기본 사전", selection: $module.site) {
                    ForEach(DictionarySite.allCases) { Text($0.title).tag($0) }
                }
                Text("단축키를 누르면 메뉴바 근처에 작은 사전 창이 열립니다. 창에서 ⌘1은 네이버, ⌘2는 다음 사전으로 바꾸며 마지막으로 고른 사전이 기억됩니다. ESC나 바깥 클릭으로 닫으면 웹 화면은 메모리에서 해제됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
