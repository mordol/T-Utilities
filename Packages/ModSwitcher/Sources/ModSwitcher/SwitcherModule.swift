import AppKit
import SwiftUI
import TUCore
import TUUI

// Design reference only: alt-tab-macos (GPL-3.0, © lwouis) — https://github.com/lwouis/alt-tab-macos.
// No code taken from it; fresh implementation.

/// Windows-style window switcher: hold ⌥ (or ⌘) and press Tab to pick a window from a grid of thumbnails.
@MainActor
@Observable
public final class SwitcherModule: TUModule {
    public static let descriptor = ModuleDescriptor(
        id: "switcher",
        displayName: "Switcher",
        symbol: "rectangle.on.rectangle",
        requiredPermissions: [.accessibility],
        enabledByDefault: false
    )

    @ObservationIgnored private let settings: ModuleSettings
    @ObservationIgnored private let tapController = SwitcherTapController()
    @ObservationIgnored private let presenter = SwitcherPresenter()

    var trigger: SwitcherTrigger {
        didSet {
            settings.set(trigger.rawValue, for: "trigger")
            tapController.trigger = trigger
        }
    }

    var mouseMode: SwitcherMouseMode {
        didSet { settings.set(mouseMode.rawValue, for: "mouseMode") }
    }

    /// Off = no capture and no Screen Recording request: windows show their app icon and title only.
    var showsThumbnails: Bool {
        didSet { settings.set(showsThumbnails, for: "showsThumbnails") }
    }

    public init(context: ModuleContext) {
        settings = context.settings
        trigger = SwitcherTrigger(rawValue: context.settings.value("trigger", default: SwitcherTrigger.option.rawValue)) ?? .option
        showsThumbnails = context.settings.value("showsThumbnails", default: true)
        mouseMode = SwitcherMouseMode(rawValue: context.settings.value("mouseMode", default: SwitcherMouseMode.click.rawValue)) ?? .click
    }

    public func start() async throws {
        tapController.trigger = trigger
        presenter.capturesThumbnails = { [weak self] in self?.showsThumbnails ?? false }
        presenter.mouseMode = { [weak self] in self?.mouseMode ?? .click }
        tapController.onCommand = { [weak self] in self?.presenter.handle($0) }
        tapController.start()
    }

    public func stop() async {
        tapController.stop()
        tapController.onCommand = nil
        presenter.close()
    }

    public var status: ModuleStatus {
        if !Permission.accessibility.isGranted { return .needsPermission(.accessibility) }
        if showsThumbnails, !Permission.screenRecording.isGranted {
            return .degraded("화면 기록 권한이 없어 썸네일 대신 앱 아이콘을 표시합니다.")
        }
        return .running
    }

    public func makeSettingsView() -> AnyView {
        AnyView(SwitcherSettingsView(module: self))
    }
}

private struct SwitcherSettingsView: View {
    @Bindable var module: SwitcherModule
    @State private var accessibilityGranted = Permission.accessibility.isGranted
    @State private var screenRecordingGranted = Permission.screenRecording.isGranted

    var body: some View {
        Form {
            Section {
                LabeledContent("트리거") {
                    HStack(spacing: 12) {
                        if let warning = module.trigger.conflictWarning {
                            ConflictBadge(warning)
                        }
                        Picker("트리거", selection: $module.trigger) {
                            ForEach(SwitcherTrigger.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if let warning = module.trigger.conflictWarning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("단축키")
            } footer: {
                Text("트리거 키를 누른 채 Tab을 누르면 현재 Space의 창과 최소화된 창이 최근에 쓴 순서로 나타납니다. Tab으로 다음, ⇧Tab으로 이전 창을 고르고, ←/→/↑/↓로도 옮길 수 있습니다. 트리거 키를 놓으면 선택한 창으로 전환하고, Esc는 취소합니다. alt-tab-macos를 참고했습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("마우스", selection: $module.mouseMode) {
                    ForEach(SwitcherMouseMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("마우스")
            } footer: {
                Text("창을 클릭하면 바로 전환합니다. 호버로 선택을 고르면 마우스를 올린 창이 선택되고, 트리거 키를 놓으면 그 창으로 전환합니다. 선택했거나 마우스를 올린 창의 오른쪽 위 전원 버튼을 누르면 그 창을 닫습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("창 썸네일 표시", isOn: $module.showsThumbnails)
                if module.showsThumbnails, !screenRecordingGranted {
                    LabeledContent {
                        Button("화면 기록 허용하기…") { Permission.screenRecording.request() }
                    } label: {
                        Label("썸네일을 표시하려면 화면 기록 권한이 필요합니다", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("표시")
            } footer: {
                Text("전환기를 열 때만 창을 한 번씩 캡처하며, 평소에는 아무것도 실행하지 않습니다. 끄거나 권한이 없으면 앱 아이콘과 창 제목만 보여 줍니다. 최소화된 창은 항상 앱 아이콘으로 표시됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !accessibilityGranted {
                Section {
                    LabeledContent {
                        Button("허용하기…") { Permission.accessibility.request() }
                    } label: {
                        Label("창을 전환하려면 손쉬운 사용 권한이 필요합니다", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                accessibilityGranted = Permission.accessibility.isGranted
                screenRecordingGranted = Permission.screenRecording.isGranted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
