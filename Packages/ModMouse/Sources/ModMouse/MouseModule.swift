import AppKit
import SwiftUI
import TUCore
import TUUI

// Mouse features adapted from LinearMouse (MIT, © LinearMouse) — https://github.com/linearmouse/linearmouse

/// Pointer speed/acceleration, side-button actions, wheel corrections and Logitech HID++ battery.
@MainActor
@Observable
public final class MouseModule: TUModule {
    public static let descriptor = ModuleDescriptor(
        id: "mouse",
        displayName: "Mouse",
        symbol: "computermouse",
        requiredPermissions: [.accessibility],
        hasPopoverSection: true,
        // An event-tap bug can break input, so the user opts in.
        enabledByDefault: false,
        conflictingBundleIDs: ["com.lujjjh.LinearMouse"]
    )

    /// HID++ battery poll; devices also push battery events in between.
    static let batteryPollInterval: Duration = .seconds(300)
    /// Defaults carried over from the user's LinearMouse config.
    static let defaultSpeed = 0.08
    static let defaultAcceleration = 0.9

    @ObservationIgnored private let settings: ModuleSettings
    @ObservationIgnored private let pointer = PointerTuner()
    @ObservationIgnored private let eventTap = MouseEventTap()
    @ObservationIgnored private let battery = LogitechBattery()
    @ObservationIgnored private var batteryPoller: Task<Void, Never>?
    @ObservationIgnored private var reapplyTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshingBattery = false
    @ObservationIgnored private var isStarted = false

    private(set) var batteries: [MouseBatteryInfo] = []
    private(set) var tapInstalled = false
    /// Mice the last pointer apply reached, for the settings diagnosis line.
    private(set) var pointerDevices: [PointerTuner.DeviceStatus] = []

    /// Off skips HID++ entirely — no device access, no polling, nothing shown.
    var showBattery: Bool {
        didSet {
            settings.set(showBattery, for: "showBattery")
            guard showBattery != oldValue else { return }
            if !showBattery { stopBattery() } else if isStarted { startBattery() }
        }
    }
    var isBatteryMonitoring: Bool { batteryPoller != nil }

    var pointerEnabled: Bool {
        didSet { settings.set(pointerEnabled, for: "pointerEnabled"); applyPointer() }
    }
    var speed: Double {
        didSet { settings.set(speed, for: "speed"); applyPointer() }
    }
    var acceleration: Double {
        didSet { settings.set(acceleration, for: "acceleration"); applyPointer() }
    }
    var backButtonAction: MouseAction {
        didSet { settings.set(backButtonAction.rawValue, for: "button3"); applyEventTapConfig() }
    }
    var forwardButtonAction: MouseAction {
        didSet { settings.set(forwardButtonAction.rawValue, for: "button4"); applyEventTapConfig() }
    }
    var reverseScroll: Bool {
        didSet { settings.set(reverseScroll, for: "reverseScroll"); applyEventTapConfig() }
    }
    /// 0 = macOS default (accelerated).
    var scrollLines: Int {
        didSet { settings.set(scrollLines, for: "scrollLines"); applyEventTapConfig() }
    }

    public init(context: ModuleContext) {
        settings = context.settings
        showBattery = context.settings.value("showBattery", default: true)
        pointerEnabled = context.settings.value("pointerEnabled", default: true)
        speed = context.settings.value("speed", default: Self.defaultSpeed)
        acceleration = context.settings.value("acceleration", default: Self.defaultAcceleration)
        backButtonAction = MouseAction(rawValue: context.settings.value("button3", default: "")) ?? .showDesktop
        forwardButtonAction = MouseAction(rawValue: context.settings.value("button4", default: "")) ?? .missionControl
        reverseScroll = context.settings.value("reverseScroll", default: false)
        scrollLines = context.settings.value("scrollLines", default: 0)
    }

    public func start() async throws {
        applyPointer()
        pointer.watchDevices { [weak self] in self?.devicesChanged() }

        applyEventTapConfig()
        installEventTap()

        isStarted = true
        if showBattery { startBattery() }
    }

    public func stop() async {
        isStarted = false
        reapplyTask?.cancel()
        reapplyTask = nil
        eventTap.stop()
        tapInstalled = false
        pointer.stopWatching()
        pointer.restore()
        stopBattery()
    }

    public var status: ModuleStatus {
        tapInstalled ? .running : .needsPermission(.accessibility)
    }

    // MARK: - Pointer

    private func applyPointer() {
        if pointerEnabled {
            pointerDevices = pointer.apply(.init(speed: speed, acceleration: acceleration))
        } else {
            pointer.restore()
            pointerDevices = []
        }
    }

    /// New or re-enumerated mice (receiver replugged, wake from sleep) start with system values.
    private func devicesChanged() {
        reapplyTask?.cancel()
        reapplyTask = Task { [weak self] in
            // A re-enumerated mouse needs a fresh event-system client, and its service may take a moment to
            // accept properties; retry once if a device still rejects the values.
            for delay in [1, 2] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, isStarted else { return }
                pointer.resetClient()
                applyPointer()
                if pointerDevices.allSatisfy(\.applied) { break }
            }
            await self?.refreshBattery()
        }
    }

    // MARK: - Event tap

    private func applyEventTapConfig() {
        eventTap.buttonActions = [3: backButtonAction, 4: forwardButtonAction]
        eventTap.scroll = ScrollOptions(reverse: reverseScroll, lines: scrollLines)
    }

    private func installEventTap() {
        eventTap.onInstalledChange = { [weak self] in self?.tapInstalled = $0 }
        eventTap.start()
    }

    // MARK: - Battery

    func startBattery() {
        battery.onChange = { [weak self] in self?.batteries = $0 }
        battery.start()
        batteryPoller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshBattery()
                try? await Task.sleep(for: Self.batteryPollInterval)
            }
        }
    }

    func stopBattery() {
        batteryPoller?.cancel()
        batteryPoller = nil
        battery.onChange = nil
        battery.stop()
        batteries = []
    }

    func refreshBattery() async {
        guard isBatteryMonitoring, !isRefreshingBattery else { return }
        isRefreshingBattery = true
        defer { isRefreshingBattery = false }
        await battery.refresh()
    }

    // MARK: - Shell integration

    public func makePopoverSection() -> AnyView? {
        showBattery ? AnyView(MouseSectionView(module: self)) : nil
    }

    public func makeSettingsView() -> AnyView {
        AnyView(MouseSettingsView(module: self))
    }

    nonisolated static func shortName(_ name: String) -> String {
        // "G304 Lightspeed Wireless Gaming Mouse" → "G304"
        name.split(separator: " ").first.map(String.init) ?? name
    }

    nonisolated static func batterySymbol(_ reading: BatteryReading) -> String {
        if reading.chargeState == .charging { return "battery.100percent.bolt" }
        switch reading.level ?? 0 {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

private struct MouseSectionView: View {
    let module: MouseModule

    var body: some View {
        if module.batteries.isEmpty {
            SectionRow(symbol: "computermouse", title: "Mouse") {
                Text("배터리 정보 없음")
            }
        }
        ForEach(module.batteries) { info in
            SectionRow(symbol: "computermouse", title: MouseModule.shortName(info.name)) {
                HStack(spacing: 4) {
                    Image(systemName: MouseModule.batterySymbol(info.reading))
                        .foregroundStyle((info.reading.level ?? 100) <= 15 ? .red : .secondary)
                    Text(info.reading.level.map { "\($0)%" } ?? "—")
                }
            }
            .help(info.name)
        }
    }
}

private struct MouseSettingsView: View {
    @Bindable var module: MouseModule

    var body: some View {
        Form {
            Section("배터리") {
                Toggle("Logitech 마우스 배터리 표시", isOn: $module.showBattery)
                if module.showBattery {
                    if module.batteries.isEmpty {
                        Text("Logitech HID++ 장치를 찾지 못했습니다 (마우스가 잠들어 있으면 움직인 뒤 새로 고침)")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(module.batteries) { info in
                        LabeledContent(info.name) {
                            HStack(spacing: 4) {
                                Image(systemName: MouseModule.batterySymbol(info.reading))
                                    .foregroundStyle((info.reading.level ?? 100) <= 15 ? .red : .secondary)
                                Text(info.reading.level.map { "\($0)%" } ?? "—").monospacedDigit()
                            }
                        }
                    }
                    Button("새로 고침") { Task { await module.refreshBattery() } }
                }
            }

            if !module.tapInstalled {
                Section {
                    LabeledContent {
                        Button("허용하기…") { Permission.accessibility.request() }
                    } label: {
                        Label("버튼·스크롤 기능에는 손쉬운 사용 권한이 필요합니다", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Toggle("포인터 설정 적용", isOn: $module.pointerEnabled)
                PointerValueRow(title: "속도", value: $module.speed, range: 0...1)
                    .disabled(!module.pointerEnabled)
                PointerValueRow(title: "가속", value: $module.acceleration, range: 0...3)
                    .disabled(!module.pointerEnabled)
                if module.pointerEnabled {
                    PointerDevicesRow(devices: module.pointerDevices)
                }
                Button("LinearMouse 값으로 되돌리기 (속도 0.08 · 가속 0.9)") {
                    module.speed = MouseModule.defaultSpeed
                    module.acceleration = MouseModule.defaultAcceleration
                }
            } header: {
                Text("포인터")
            } footer: {
                Text("연결된 모든 마우스에 적용됩니다(트랙패드 제외). 모듈을 끄거나 앱을 종료하면 원래 값으로 돌아갑니다. 시스템 설정에서 추적 속도를 바꾸면 그 값이 우선합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("측면 버튼") {
                Picker("뒤로 버튼 (3)", selection: $module.backButtonAction) {
                    ForEach(MouseAction.allCases) { Text($0.title).tag($0) }
                }
                Picker("앞으로 버튼 (4)", selection: $module.forwardButtonAction) {
                    ForEach(MouseAction.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Toggle("스크롤 방향 반전", isOn: $module.reverseScroll)
                Picker("휠 한 칸당", selection: $module.scrollLines) {
                    Text("macOS 기본 (가속)").tag(0)
                    ForEach([1, 2, 3, 4, 5, 6, 8, 10], id: \.self) { Text("\($0)줄").tag($0) }
                }
            } header: {
                Text("스크롤 보정")
            } footer: {
                Text("마우스 휠에만 적용되고 트랙패드에는 적용되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }
}

/// Slider for coarse moves plus a number field for fine values (#24); typed values are clamped to the range.
private struct PointerValueRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                TextField(title, value: clamped, format: .number.precision(.fractionLength(2...3)))
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
            }
        }
    }

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = $0.clamped(range.lowerBound, range.upperBound) })
    }
}

/// Which mice the pointer settings reached, so "speed doesn't change" can be told apart from "no mouse found".
private struct PointerDevicesRow: View {
    let devices: [PointerTuner.DeviceStatus]

    var body: some View {
        if devices.isEmpty {
            Label("감지된 마우스가 없습니다", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            ForEach(devices) { device in
                if device.applied {
                    Label("적용 중: \(device.name)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("적용 실패: \(device.name) — macOS가 값을 받아들이지 않았습니다", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
