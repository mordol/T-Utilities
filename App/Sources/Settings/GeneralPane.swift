import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import TUCore
import TUUI

struct GeneralPane: View {
    let registry: ModuleRegistry
    let updater: Updater
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var showsLicenses = false

    var body: some View {
        Form {
            Section {
                Toggle("로그인 시 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("단축키") {
                let hotkeys = registry.activeModules.flatMap { module in
                    module.hotkeys.map { (module: type(of: module).descriptor, hotkey: $0) }
                }
                if hotkeys.isEmpty {
                    Text("활성 모듈에 단축키가 없습니다").foregroundStyle(.secondary)
                }
                ForEach(hotkeys, id: \.hotkey.name.rawValue) { item in
                    HotkeyRow(module: item.module, hotkey: item.hotkey)
                }
            }

            Section("업데이트") {
                LabeledContent("현재 버전", value: updater.currentVersion)
                HStack {
                    updateStatus
                    Spacer()
                    if case .available(let release) = updater.state {
                        Link("릴리스 노트", destination: release.pageURL)
                        Button("설치 후 다시 실행", action: updater.install)
                    } else {
                        Button("지금 확인") { Task { await updater.check() } }
                            .disabled(updater.state == .checking || updater.isInstalling)
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { registry.showsBeta },
                    set: { shows in Task { await registry.setShowsBeta(shows) } }
                )) {
                    Text("베타 기능 표시")
                    Text("개발 중인 모듈을 목록에 표시합니다. 표시한 뒤 모듈 설정에서 켜야 동작합니다. 불안정할 수 있습니다.")
                }
            }

            Section {
                Button("오픈소스 라이선스…") { showsLicenses = true }
            }

            let conflicts = runningConflicts
            if !conflicts.isEmpty {
                Section("충돌하는 앱") {
                    ForEach(conflicts, id: \.app) { conflict in
                        Label(
                            "\(conflict.app)이(가) 실행 중입니다. \(conflict.module) 모듈과 동시에 사용하면 기능이 중복 적용됩니다.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("일반")
        .sheet(isPresented: $showsLicenses) {
            LicensesView { showsLicenses = false }
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle: Text("아직 확인하지 않음").foregroundStyle(.secondary)
        case .checking: Text("확인 중…").foregroundStyle(.secondary)
        case .upToDate: Text("최신 버전입니다").foregroundStyle(.secondary)
        case .available(let release): Text("업데이트 가능 v\(release.version)")
        case .installing(let release): Text("v\(release.version) 설치 중…").foregroundStyle(.secondary)
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
    }

    private var runningConflicts: [(app: String, module: String)] {
        let running = NSWorkspace.shared.runningApplications
        return registry.descriptors
            .filter { registry.isEnabled($0.id) }
            .flatMap { descriptor in
                running
                    .filter { app in descriptor.conflictingBundleIDs.contains(app.bundleIdentifier ?? "") }
                    .map { (app: $0.localizedName ?? $0.bundleIdentifier ?? "?", module: descriptor.displayName) }
            }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Shortcut recorder with a conflict badge when the current combination is known to clash.
private struct HotkeyRow: View {
    let module: ModuleDescriptor
    let hotkey: HotkeyDefinition
    @State private var shortcut: KeyboardShortcuts.Shortcut?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let shortcut, let warning = hotkey.conflicts[shortcut] {
                    ConflictBadge(warning)
                }
                KeyboardShortcuts.Recorder(for: hotkey.name) { shortcut = $0 }
            }
        } label: {
            Label("\(module.displayName) · \(hotkey.title)", systemImage: module.symbol)
        }
        .onAppear { shortcut = KeyboardShortcuts.getShortcut(for: hotkey.name) }
    }
}

/// T-Utilities' own license followed by the third-party notices bundled with the app.
private struct LicensesView: View {
    let close: () -> Void

    private var text: String {
        ["LICENSE", "THIRD_PARTY_NOTICES.md"]
            .compactMap { Bundle.main.url(forResource: $0, withExtension: nil) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n\n────────────────────────\n\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("닫기", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 620, height: 520)
    }
}
