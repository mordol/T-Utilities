import AppKit
import KeyboardShortcuts
import SwiftUI
import TUCore
import TUUI

// Window actions adapted from Rectangle (MIT, © Ryan Hanson; based on Spectacle © Eric Czarny)
// https://github.com/rxhanson/Rectangle — only Maximize and Next/Previous Display, with Rectangle's default shortcuts.

extension KeyboardShortcuts.Name {
    static let windowMaximize = Self("windows.maximize", initial: .init(.return, modifiers: [.control, .option]))
    static let windowNextDisplay = Self("windows.nextDisplay", initial: .init(.rightArrow, modifiers: [.control, .option, .command]))
    static let windowPreviousDisplay = Self("windows.previousDisplay", initial: .init(.leftArrow, modifiers: [.control, .option, .command]))
}

@MainActor
@Observable
public final class WindowsModule: TUModule {
    public static let descriptor = ModuleDescriptor(
        id: "windows",
        displayName: "Windows",
        symbol: "macwindow",
        requiredPermissions: [.accessibility],
        conflictingBundleIDs: ["com.knollsoft.Rectangle", "org.dmarcotte.Easy-Move-Resize"]
    )

    /// A window maximized by us and where it was before, so pressing Maximize again restores it.
    private struct RestoreEntry {
        let window: AXUIElement
        let original: CGRect
        let maximized: CGRect
    }

    @ObservationIgnored private var restoreEntries: [RestoreEntry] = []
    private static let maxRestoreEntries = 20

    @ObservationIgnored private let settings: ModuleSettings
    @ObservationIgnored private let edgeSnap = EdgeResizeSnap()
    @ObservationIgnored private let modifierDragController = ModifierDragController()

    /// Drag a window's top/bottom edge to the screen edge → full height (Windows-style).
    var edgeVerticalFill: Bool {
        didSet {
            settings.set(edgeVerticalFill, for: "edgeVerticalFill")
            edgeVerticalFill ? edgeSnap.start() : edgeSnap.stop()
        }
    }

    /// Hold the modifier and drag anywhere in a window to move it, right-drag to resize (easy-move-resize).
    var modifierDrag: Bool {
        didSet {
            settings.set(modifierDrag, for: "modifierDrag")
            modifierDrag ? modifierDragController.start() : modifierDragController.stop()
        }
    }

    var modifierDragKeys: DragModifiers {
        didSet {
            settings.set(modifierDragKeys.rawValue, for: "modifierDragKeys")
            modifierDragController.modifiers = modifierDragKeys
        }
    }

    public init(context: ModuleContext) {
        settings = context.settings
        edgeVerticalFill = context.settings.value("edgeVerticalFill", default: true)
        modifierDrag = context.settings.value("modifierDrag", default: true)
        modifierDragKeys = .stored(context.settings.value("modifierDragKeys", default: DragModifiers.default.rawValue))
    }

    public func start() async throws {
        if edgeVerticalFill { edgeSnap.start() }
        modifierDragController.modifiers = modifierDragKeys
        modifierDragController.onDoubleClick = { [weak self] window in self?.perform(.maximize, on: window) }
        if modifierDrag { modifierDragController.start() }
    }

    public func stop() async {
        edgeSnap.stop()
        modifierDragController.stop()
    }

    public var status: ModuleStatus {
        Permission.accessibility.isGranted ? .running : .needsPermission(.accessibility)
    }

    public var hotkeys: [HotkeyDefinition] {
        [
            HotkeyDefinition(name: .windowMaximize, title: "최대화") { [weak self] in self?.perform(.maximize) },
            HotkeyDefinition(name: .windowNextDisplay, title: "다음 디스플레이") { [weak self] in self?.perform(.nextDisplay) },
            HotkeyDefinition(name: .windowPreviousDisplay, title: "이전 디스플레이") { [weak self] in self?.perform(.previousDisplay) },
        ]
    }

    public func makeSettingsView() -> AnyView {
        AnyView(WindowsSettingsView(module: self))
    }

    // MARK: - Actions

    /// Acts on `target`, or the frontmost app's focused window when nil (hotkeys).
    func perform(_ action: WindowLayout.Action, on target: AXWindow? = nil) {
        guard Permission.accessibility.isGranted else {
            Permission.accessibility.request()
            return
        }
        guard let window = target ?? AXWindow.frontmost(), !window.isSheet,
              let axFrame = window.frame,
              let primaryMaxY = NSScreen.screens.first?.frame.maxY else {
            NSSound.beep()
            return
        }
        if action == .maximize, let index = restoreEntries.firstIndex(where: { CFEqual($0.window, window.element) }) {
            let entry = restoreEntries.remove(at: index)
            // Still exactly as we left it → toggle back. Moved/resized since → maximize again.
            if WindowLayout.isSameFrame(entry.maximized, axFrame) {
                window.setFrame(entry.original)
                return
            }
        }

        let screens = NSScreen.screens.map { WindowLayout.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let current = WindowLayout.flipped(axFrame, primaryScreenMaxY: primaryMaxY)
        guard var target = WindowLayout.target(for: action, window: current, screens: screens) else {
            NSSound.beep()
            return
        }

        // Fixed-size windows can only be moved: keep their size, centered in the target area.
        if !window.isResizable {
            target = CGRect(
                x: target.midX - current.width / 2, y: target.midY - current.height / 2,
                width: current.width, height: current.height
            )
        }
        window.setFrame(WindowLayout.flipped(target, primaryScreenMaxY: primaryMaxY))
        defer {
            if action == .maximize, let placed = window.frame {
                restoreEntries.append(RestoreEntry(window: window.element, original: axFrame, maximized: placed))
                restoreEntries = Array(restoreEntries.suffix(Self.maxRestoreEntries))
            }
        }

        // Windows with a minimum size may refuse the target and end up partly off-screen.
        guard let destination = WindowLayout.screenContaining(target, in: screens),
              let placed = window.frame else { return }
        let placedCocoa = WindowLayout.flipped(placed, primaryScreenMaxY: primaryMaxY)
        let fitted = WindowLayout.constrained(placedCocoa, to: destination.visibleFrame)
        if fitted.origin != placedCocoa.origin {
            window.set(position: WindowLayout.flipped(fitted, primaryScreenMaxY: primaryMaxY).origin)
        }
    }
}

/// macOS' own "Drag windows to menu bar to fill screen" (System Settings → Desktop & Dock → Windows).
enum SystemTopEdgeFill {
    private static let domain = "com.apple.WindowManager"
    private static let key = "EnableTopTilingByEdgeDrag"

    /// Missing key = macOS default (on).
    static var isEnabled: Bool {
        get { (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool) ?? true }
        set {
            // module-rules: allow proxies a macOS setting the user toggles explicitly in this pane
            CFPreferencesSetAppValue(key as CFString, newValue as CFBoolean, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
        }
    }
}

private struct ModifierKeyOption: Identifiable {
    let key: DragModifiers
    let label: String
    var id: Int { key.rawValue }

    static let all = [
        ModifierKeyOption(key: .control, label: "⌃"),
        ModifierKeyOption(key: .option, label: "⌥"),
        ModifierKeyOption(key: .shift, label: "⇧"),
        ModifierKeyOption(key: .command, label: "⌘"),
    ]
}

private struct WindowsSettingsView: View {
    @Bindable var module: WindowsModule
    @State private var granted = Permission.accessibility.isGranted
    @State private var topEdgeFill = SystemTopEdgeFill.isEnabled

    var body: some View {
        Form {
            Section {
                LabeledContent("최대화", value: "⌃⌥↩")
                LabeledContent("다음 디스플레이", value: "⌃⌥⌘→")
                LabeledContent("이전 디스플레이", value: "⌃⌥⌘←")
            } header: {
                Text("기본 단축키")
            } footer: {
                Text("단축키는 설정 → 일반에서 바꿀 수 있습니다. Rectangle이 실행 중이면 같은 단축키가 충돌하니 종료하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("창 위·아래 가장자리를 화면 끝까지 끌면 세로로 채우기", isOn: $module.edgeVerticalFill)
            } header: {
                Text("드래그")
            } footer: {
                Text("창의 위나 아래 가장자리를 잡고 메뉴 막대나 Dock 쪽 끝까지 끌면 미리보기가 나타나고, 놓으면 가로 크기는 그대로 높이만 화면에 맞춥니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("수정키를 누르고 창 어디서든 끌어 이동·크기 조절", isOn: $module.modifierDrag)
                if module.modifierDrag {
                    LabeledContent("수정키") {
                        HStack(spacing: 12) {
                            if let warning = module.modifierDragKeys.conflictWarning {
                                ConflictBadge(warning)
                            }
                            ForEach(ModifierKeyOption.all) { option in
                                Toggle(option.label, isOn: Binding(
                                    get: { module.modifierDragKeys.contains(option.key) },
                                    set: { on in
                                        var keys = module.modifierDragKeys
                                        if on { keys.insert(option.key) } else { keys.remove(option.key) }
                                        // At least one key stays armed, or every plain click would be swallowed.
                                        if !keys.isEmpty { module.modifierDragKeys = keys }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            } header: {
                Text("수정키 드래그")
            } footer: {
                Text("수정키를 누른 채 창 안을 끌면 이동하고, 오른쪽 버튼으로 끌면 커서가 있는 모서리 쪽으로 크기를 조절합니다. 수정키를 누른 채 더블클릭하면 최대화하고, 다시 더블클릭하면 이전 크기로 돌아갑니다. 수정키를 누른 클릭은 아래 앱에 전달되지 않습니다. easy-move-resize를 참고했습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("창을 메뉴 막대로 끌어 화면 채우기", isOn: $topEdgeFill)
                    .onChange(of: topEdgeFill) { _, enabled in SystemTopEdgeFill.isEnabled = enabled }
            } header: {
                Text("macOS 창 기능")
            } footer: {
                Text("macOS 기본 기능의 설정입니다 (시스템 설정 → 데스크탑 및 Dock → 윈도우).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !granted {
                Section {
                    LabeledContent {
                        Button("허용하기…") { Permission.accessibility.request() }
                    } label: {
                        Label("창을 옮기려면 손쉬운 사용 권한이 필요합니다", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                granted = Permission.accessibility.isGranted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
