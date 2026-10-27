import AppKit
import ClamshellKit
import SwiftUI
import TUCore
import TUUI

/// Sleep prevention: off / manual (timed) / auto (while coding agents work),
/// optionally also with the lid closed (no external display needed).
@MainActor
@Observable
public final class AwakeModule: TUModule {
    public static let descriptor = ModuleDescriptor(
        id: "awake",
        displayName: "Awake",
        symbol: "cup.and.saucer",
        hasPopoverSection: true,
        conflictingBundleIDs: ["com.jadhvank.eclam", "com.if.Amphetamine", "info.marcel-dierkes.KeepingYouAwake"]
    )

    static let pollInterval: Duration = .seconds(5)
    static let manualDurations: [TimeInterval] = [3600, 3 * 3600, 0] // 0 = unlimited

    @ObservationIgnored private let settings: ModuleSettings
    @ObservationIgnored private let assertion = SleepAssertion()
    @ObservationIgnored private let lidGuard = LidSleepGuard()
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Ticks also come from settings and the popover (`setMode`), which can outlive a disable, and a tick
    /// suspends during agent detection; without this check a tick finishing after `stop()` re-acquires the
    /// sleep assertion and lid-closed prevention.
    @ObservationIgnored private var isStarted = false

    private(set) var mode: AwakeMode
    /// End of the current manual session; nil = unlimited.
    private(set) var manualUntil: Date?
    /// Length of the running timed manual session, for the draining menu bar icon.
    private(set) var manualTotal: TimeInterval
    private(set) var activeAgents: [DetectedAgent] = []
    private(set) var lastAgentActivity: Date?
    private(set) var isHolding = false
    private(set) var isLidSleepPrevented = false
    /// Why prevention was released by a safety guard (battery/thermal), if it was.
    private(set) var guardReason: String?
    private(set) var now = Date()

    /// Seconds; 0 = unlimited.
    var manualDuration: TimeInterval {
        didSet { settings.set(manualDuration, for: "manualDuration") }
    }
    var grace: TimeInterval {
        didSet { settings.set(grace, for: "grace") }
    }
    var sources: Set<AgentDetector.Source> {
        didSet { settings.set(sources.map(\.rawValue).sorted(), for: "sources") }
    }
    var countsPermissionWait: Bool {
        didSet { settings.set(countsPermissionWait, for: "countsPermissionWait") }
    }
    var preventsLidSleep: Bool {
        didSet { settings.set(preventsLidSleep, for: "preventsLidSleep"); Task { await tick() } }
    }
    /// Release prevention on battery at or below this percent; 0 = off.
    var batteryThreshold: Int {
        didSet { settings.set(batteryThreshold, for: "batteryThreshold") }
    }
    var thermalGuard: Bool {
        didSet { settings.set(thermalGuard, for: "thermalGuard") }
    }

    public init(context: ModuleContext) {
        settings = context.settings
        mode = AwakeMode(rawValue: context.settings.value("mode", default: "off")) ?? .off
        manualUntil = context.settings.value("manualUntil", default: nil as Date?)
        manualTotal = context.settings.value("manualTotal", default: 3 * 3600)
        let savedDuration: TimeInterval = context.settings.value("manualDuration", default: 3 * 3600)
        // Older versions also offered 8 hours.
        manualDuration = Self.manualDurations.contains(savedDuration) ? savedDuration : 3 * 3600
        grace = context.settings.value("grace", default: 60)
        let savedSources: [String] = context.settings.value("sources", default: AgentDetector.Source.allCases.map(\.rawValue))
        sources = Set(savedSources.compactMap(AgentDetector.Source.init(rawValue:)))
        countsPermissionWait = context.settings.value("countsPermissionWait", default: true)
        preventsLidSleep = context.settings.value("preventsLidSleep", default: true)
        batteryThreshold = context.settings.value("batteryThreshold", default: 20)
        thermalGuard = context.settings.value("thermalGuard", default: true)
    }

    public func start() async throws {
        // A previous run may have died while lid-closed sleep was disabled (and its guard with it).
        ClamshellMarker().recoverIfNeeded()
        isStarted = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    public func stop() async {
        isStarted = false
        loop?.cancel()
        loop = nil
        assertion.set(false, reason: "")
        lidGuard.deactivate()
        isHolding = false
        isLidSleepPrevented = false
    }

    // MARK: - Mode

    func setMode(_ newMode: AwakeMode) {
        mode = newMode
        manualUntil = newMode == .manual && manualDuration > 0 ? Date().addingTimeInterval(manualDuration) : nil
        manualTotal = manualDuration
        settings.set(mode.rawValue, for: "mode")
        settings.set(manualUntil, for: "manualUntil")
        settings.set(manualTotal, for: "manualTotal")
        Task { await tick() }
    }

    func startManual(duration: TimeInterval) {
        manualDuration = duration
        setMode(.manual)
    }

    private func tick() async {
        guard isStarted else { return }
        now = Date()
        if mode == .auto {
            let detector = AgentDetector(
                home: FileManager.default.homeDirectoryForCurrentUser,
                sources: sources,
                countsPermissionWait: countsPermissionWait
            )
            let detected = await Task.detached(priority: .utility) { detector.detect() }.value
            guard isStarted else { return }
            activeAgents = detected
            if !detected.isEmpty { lastAgentActivity = now }
        } else {
            activeAgents = []
            lastAgentActivity = nil
        }

        if mode == .manual, let manualUntil, now >= manualUntil {
            setMode(.off)
            return
        }

        let wanted = AwakePolicy.shouldHold(
            mode: mode, manualUntil: manualUntil, lastAgentActivity: lastAgentActivity, now: now, grace: grace
        )
        guardReason = wanted
            ? PowerGuard.tripReason(PowerGuard.current(), batteryThreshold: batteryThreshold, thermalGuard: thermalGuard)
            : nil
        isHolding = wanted && guardReason == nil
        assertion.set(isHolding, reason: "T-Utilities Awake (\(mode.rawValue))")

        if isHolding && preventsLidSleep {
            if !lidGuard.isActive { lidGuard.activate() }
        } else {
            lidGuard.deactivate()
        }
        isLidSleepPrevented = lidGuard.isActive
    }

    // MARK: - Shell integration

    /// 2×2 grid: off = all outlined, manual = top-left filled, auto = top row filled.
    public var statusItemImage: NSImage? {
        GridIcon.image(Self.iconCells(mode: mode, remaining: manualUntil.map { $0.timeIntervalSince(now) }, total: manualTotal))
    }

    /// off: 4 empty · auto: 4 light · manual unlimited: 4 filled · timed manual: 3 filled (not bottom-right),
    /// emptying bottom-left → top-right → top-left as each third of the time runs out.
    nonisolated static func iconCells(mode: AwakeMode, remaining: TimeInterval?, total: TimeInterval) -> [GridIcon.Cell] {
        switch mode {
        case .off:
            return [.empty, .empty, .empty, .empty]
        case .auto:
            return [.light, .light, .light, .light]
        case .manual:
            guard let remaining else { return [.filled, .filled, .filled, .filled] }
            let fraction = total > 0 ? remaining / total : 0
            if fraction > 2.0 / 3 { return [.filled, .filled, .filled, .empty] }
            if fraction > 1.0 / 3 { return [.filled, .filled, .empty, .empty] }
            return [.filled, .empty, .empty, .empty]
        }
    }

    public func makePopoverSection() -> AnyView? {
        AnyView(AwakeSectionView(module: self))
    }

    public func makeSettingsView() -> AnyView {
        AnyView(AwakeSettingsView(module: self))
    }

    public func makeQuickMenuItems() -> [NSMenuItem] {
        let header = NSMenuItem(title: "Awake", action: nil, keyEquivalent: "")
        header.isEnabled = false
        return [
            header,
            ClosureMenuItem("끔", isChecked: mode == .off) { [weak self] in self?.setMode(.off) },
            ClosureMenuItem("수동 (\(Self.durationLabel(manualDuration)))", isChecked: mode == .manual) { [weak self] in
                self?.setMode(.manual)
            },
            ClosureMenuItem("자동 (에이전트 감지)", isChecked: mode == .auto) { [weak self] in self?.setMode(.auto) },
        ]
    }

    // MARK: - Display

    var summary: String {
        if let guardReason {
            return "일시 중지 · \(guardReason)"
        }
        switch mode {
        case .off:
            return "잠자기 허용"
        case .manual:
            guard let manualUntil else { return "무제한 유지 중" }
            return "\(Self.remainingLabel(manualUntil.timeIntervalSince(now))) 남음"
        case .auto:
            if !activeAgents.isEmpty {
                return "작업 중 · \(activeAgents.map(\.name).joined(separator: ", "))"
            }
            if isHolding, let lastAgentActivity {
                let left = max(0, Int(grace - now.timeIntervalSince(lastAgentActivity)))
                return "작업 종료 · \(left)초 후 해제"
            }
            return "에이전트 대기 중"
        }
    }

    nonisolated static func durationLabel(_ seconds: TimeInterval) -> String {
        seconds == 0 ? "무제한" : "\(Int(seconds / 3600))시간"
    }

    nonisolated static func remainingLabel(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.up)))
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }
}

// MARK: - Views

private struct AwakeSectionView: View {
    let module: AwakeModule

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: module.statusItemImage ?? GridIcon.image())
                    .renderingMode(.template)
                    .frame(width: 18)
                    .foregroundStyle(module.isHolding ? Color.accentColor : .secondary)
                Text("Awake")
                Spacer()
                Picker("Awake", selection: Binding(get: { module.mode }, set: { module.setMode($0) })) {
                    ForEach(AwakeMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack(spacing: 6) {
                Text(module.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if module.mode == .manual {
                    Picker("시간", selection: Binding(get: { module.manualDuration }, set: { module.startManual(duration: $0) })) {
                        ForEach(AwakeModule.manualDurations, id: \.self) { Text(AwakeModule.durationLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct AwakeSettingsView: View {
    @Bindable var module: AwakeModule

    var body: some View {
        Form {
            Section("상태") {
                LabeledContent("모드", value: module.mode.displayName)
                LabeledContent("잠자기 방지", value: module.isHolding ? "켜짐" : "꺼짐")
                LabeledContent("뚜껑 닫힘 방지", value: module.isLidSleepPrevented ? "켜짐" : "꺼짐")
                LabeledContent("상세", value: module.summary)
            }
            Section("수동") {
                Picker("기본 유지 시간", selection: $module.manualDuration) {
                    ForEach(AwakeModule.manualDurations, id: \.self) { Text(AwakeModule.durationLabel($0)).tag($0) }
                }
            }
            Section {
                ForEach(AgentDetector.Source.allCases, id: \.self) { source in
                    Toggle(source.displayName, isOn: Binding(
                        get: { module.sources.contains(source) },
                        set: { enabled in
                            if enabled { module.sources.insert(source) } else { module.sources.remove(source) }
                        }
                    ))
                }
                Toggle("권한 승인을 기다리는 에이전트도 작업 중으로 보기 (Paseo)", isOn: $module.countsPermissionWait)
                Picker("작업 종료 후 유지", selection: $module.grace) {
                    ForEach([30.0, 60, 120, 300], id: \.self) { Text("\(Int($0))초").tag($0) }
                }
            } header: {
                Text("자동 — 감지 대상")
            } footer: {
                Text("Paseo는 에이전트 상태 파일을, Claude·Codex·Cursor는 대화 기록 파일의 수정 시각만 확인합니다(내용은 읽지 않음). 5초마다 확인합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("뚜껑을 닫아도 잠들지 않기", isOn: $module.preventsLidSleep)
                Picker("배터리로 동작 중 이 잔량 이하이면 해제", selection: $module.batteryThreshold) {
                    ForEach([0, 10, 20, 30, 50], id: \.self) { Text($0 == 0 ? "사용 안 함" : "\($0)%").tag($0) }
                }
                Toggle("기기 과열 시 해제", isOn: $module.thermalGuard)
            } header: {
                Text("뚜껑 닫힘 · 안전")
            } footer: {
                Text("잠자기 방지가 켜져 있는 동안 외부 모니터 없이 뚜껑을 닫아도 계속 동작합니다. 앱이 비정상 종료되면 보조 프로세스가 즉시 원래대로 되돌립니다. 가방 안에서는 열이 빠지지 않으니 주의하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
