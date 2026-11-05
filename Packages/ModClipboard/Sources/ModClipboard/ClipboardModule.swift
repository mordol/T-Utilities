import AppKit
import KeyboardShortcuts
import SwiftUI
import TUCore

// Adapted from CopyNinja (MIT, © 2026 Dawoon Yi / MelissaSoft) — https://github.com/dwyi84/CopyNinja

extension KeyboardShortcuts.Name {
    static let clipboardToggle = Self("clipboard.toggle", initial: .init(.v, modifiers: [.command, .shift]))
    static let clipboardTranslate = Self("clipboard.translate", initial: .init(.t, modifiers: [.control, .option]))
    static let clipboardPlainTextPaste = Self("clipboard.plainTextPaste", initial: .init(.v, modifiers: [.command, .shift, .option]))
}

/// Clipboard history: captures text/images, search, quick slots (⌘1~0), OCR, Quick Look.
@MainActor
@Observable
public final class ClipboardModule: TUModule {
    public static let descriptor = ModuleDescriptor(
        id: "clipboard",
        displayName: "Clipboard",
        symbol: "doc.on.clipboard",
        hasPopoverSection: true,
        conflictingBundleIDs: ["com.melissasoft.CopyNinja"]
    )

    /// ANSI key codes for the top-row digits, mapped to quick slot numbers.
    private static let quickSlotKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0
    ]

    @ObservationIgnored private let popover: PopoverControl
    @ObservationIgnored private let settings: ModuleSettings
    @ObservationIgnored private let storageURL: URL
    /// App that was frontmost before the popover opened — the paste target.
    @ObservationIgnored private var previousApp: NSRunningApplication?

    /// Return (↩) also pastes into the previously focused app.
    var autoPaste: Bool {
        didSet { settings.set(autoPaste, for: "autoPaste") }
    }
    @ObservationIgnored private var store: ClipboardStore?
    @ObservationIgnored private var monitor: ClipboardMonitor?
    @ObservationIgnored private var translationPanel: TranslationPanelController?
    @ObservationIgnored private var translationTask: Task<Void, Never>?

    var translationEngine: TranslationEngine {
        didSet { settings.set(translationEngine.rawValue, for: "translationEngine") }
    }
    var primaryLanguage: TranslationLanguage {
        didSet { settings.set(primaryLanguage.rawValue, for: "translationPrimary") }
    }
    var secondaryLanguage: TranslationLanguage {
        didSet { settings.set(secondaryLanguage.rawValue, for: "translationSecondary") }
    }
    /// Extra instructions appended to the translation prompt (tone, terminology).
    var translationGuidelines: String {
        didSet { settings.set(translationGuidelines, for: "translationGuidelines") }
    }
    /// Translating an image also adds the recognized text to the clipboard history.
    var savesOCRTextOnTranslate: Bool {
        didSet { settings.set(savesOCRTextOnTranslate, for: "translationSavesOCRText") }
    }

    public required convenience init(context: ModuleContext) {
        self.init(context: context, storageURL: PersistenceManager.defaultBaseURL)
    }

    init(context: ModuleContext, storageURL: URL) {
        popover = context.popover
        settings = context.settings
        self.storageURL = storageURL
        autoPaste = context.settings.value("autoPaste", default: false)
        translationEngine = TranslationEngine(rawValue: context.settings.value("translationEngine", default: "")) ?? .claudeCLI
        primaryLanguage = TranslationLanguage(rawValue: context.settings.value("translationPrimary", default: "")) ?? .korean
        secondaryLanguage = TranslationLanguage(rawValue: context.settings.value("translationSecondary", default: "")) ?? .english
        translationGuidelines = context.settings.value("translationGuidelines", default: "")
        savesOCRTextOnTranslate = context.settings.value("translationSavesOCRText", default: true)
    }

    /// Model for `engine`; empty = the engine's default.
    func translationModel(for engine: TranslationEngine) -> String {
        settings.value("translationModel.\(engine.rawValue)", default: engine.defaultModel)
    }

    func setTranslationModel(_ model: String, for engine: TranslationEngine) {
        settings.set(model, for: "translationModel.\(engine.rawValue)")
    }

    public func start() async throws {
        let store = ClipboardStore(persistence: PersistenceManager(baseURL: storageURL))
        let monitor = ClipboardMonitor { [weak store] capture in
            store?.add(capture)
        }
        store.willWriteToClipboard = { [weak monitor] in
            monitor?.suppressNextChange()
        }
        store.onDismiss = { [popover] in
            popover.close()
        }
        monitor.start()
        self.store = store
        self.monitor = monitor

        let panel = TranslationPanelController()
        panel.onCopy = { text in
            // Not suppressed: the copied translation becomes a history entry like any other copy.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        panel.onClose = { [weak self] in self?.translationPanelDidClose() }
        translationPanel = panel
    }

    public func stop() async {
        translationTask?.cancel()
        translationTask = nil
        translationPanel?.onClose = nil
        translationPanel?.close()
        translationPanel = nil
        monitor?.stop()
        monitor = nil
        store = nil
        previousApp = nil
    }

    public var status: ModuleStatus {
        autoPaste && !Permission.accessibility.isGranted ? .needsPermission(.accessibility) : .running
    }

    public var hotkeys: [HotkeyDefinition] {
        [
            HotkeyDefinition(name: .clipboardToggle, title: "클립보드 열기/닫기") { [popover] in popover.toggle() },
            HotkeyDefinition(name: .clipboardTranslate, title: "클립보드 첫 항목 번역") { [weak self] in
                guard let item = self?.store?.items.first else {
                    NSSound.beep()
                    return
                }
                self?.translate(item)
            },
            HotkeyDefinition(
                name: .clipboardPlainTextPaste,
                title: "서식 없이 붙여넣기",
                conflicts: [
                    .init(.v, modifiers: [.command, .shift, .option]):
                        "여러 앱의 '붙여넣고 스타일 일치'(⌥⇧⌘V)와 같은 키입니다. 앱 기능 대신 이 기능이 동작하며, 클립보드를 잠시 바꿨다 되돌리는 방식이라 느린 앱에서는 서식이 남을 수 있습니다.",
                ]
            ) { [weak self] in
                guard Permission.accessibility.isGranted else {
                    Permission.accessibility.request()
                    return
                }
                PlainTextPaste.perform { self?.monitor?.suppressNextChange() }
            }
        ]
    }

    public func makePopoverSection() -> AnyView? {
        guard let store else { return nil }
        return AnyView(ClipboardSectionView(
            store: store,
            autoPaste: autoPaste,
            onTranslate: { [weak self] item in self?.translate(item) },
            onClose: { [popover] in popover.close() }
        ))
    }

    public func makeSettingsView() -> AnyView {
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(ClipboardSettingsView(module: self, store: store))
    }

    public func popoverWillShow() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost
        store?.prepareForPresentation()
    }

    /// ↩: copy, close, and — when enabled and permitted — paste into the previously focused app.
    private func copyAndPaste(_ item: ClipboardItem, store: ClipboardStore) {
        store.copyToClipboard(item)
        popover.close()
        guard autoPaste, Permission.accessibility.isGranted, let previousApp else { return }
        Paster.paste(into: previousApp)
    }

    // MARK: - Translation

    /// Translates a history item in the translation panel; an image is OCR'd first.
    func translate(_ item: ClipboardItem) {
        guard let translationPanel else { return }
        translationTask?.cancel()
        popover.close()
        let model = TranslationPanelModel(
            engineTitle: translationEngine.title,
            phase: item.kind == .image ? .recognizing : .translating
        )
        // Next turn: the popover's close first hands focus back to the previous app, and the panel doesn't take it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.translationPanel === translationPanel else { return }
            translationPanel.show(model)
            translationTask = Task { [weak self] in await self?.runTranslation(of: item, into: model) }
        }
    }

    private func runTranslation(of item: ClipboardItem, into model: TranslationPanelModel) async {
        var text = item.text ?? ""
        if item.kind == .image {
            let recognized = await store?.runOCR(for: item)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled, let store else { return }
            guard let recognized, !recognized.isEmpty else {
                model.phase = .noText
                translationPanel?.closeAfterDelay()
                return
            }
            if savesOCRTextOnTranslate { store.registerOCRResult(recognized) }
            text = recognized
        }
        let target = TranslationPrompt.target(for: text, primary: primaryLanguage, secondary: secondaryLanguage)
        model.source = text
        model.target = target
        model.phase = .translating
        let request = TranslationRequest(
            engine: translationEngine,
            model: translationModel(for: translationEngine),
            system: TranslationPrompt.system(target: target, guidelines: translationGuidelines),
            user: TranslationPrompt.user(text)
        )
        do {
            let result = try await TranslationRunner.run(request) { partial in model.result = partial }
            guard !Task.isCancelled else { return }
            model.result = result
            model.phase = .done
        } catch {
            guard !Task.isCancelled else { return }
            model.phase = .failed(error.localizedDescription)
        }
    }

    private func translationPanelDidClose() {
        translationTask?.cancel()
        translationTask = nil
        // Opened from the popover before focus went back: return it now (the panel itself never takes it).
        if NSApp.isActive, NSApp.keyWindow == nil, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
    }

    // MARK: - Keyboard navigation

    public func handlePopoverKeyDown(_ event: NSEvent) -> Bool {
        guard let store else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode

        if keyCode == 53 { // Esc — dismiss Quick Look first; otherwise let the shell close the popover
            guard store.quickLookItem != nil else { return false }
            store.dismissQuickLook()
            return true
        }

        if flags.contains(.command) {
            if event.charactersIgnoringModifiers == "k" { // ⌘K
                store.clearAll()
                return true
            }
            if keyCode == 117 && flags.contains(.shift) { // ⌘⇧ForwardDelete
                store.clearAll()
                return true
            }
            if let slot = Self.quickSlotKeyCodes[keyCode] { // ⌘1~0 / ⌘⇧1~0
                if let item = store.quickSlotItem(slot) {
                    if flags.contains(.shift) {
                        store.performOCRCopy(for: item)
                    } else {
                        store.copyToClipboard(item)
                        popover.close()
                    }
                }
                return true
            }
            return false
        }
        if flags.contains(.option) || flags.contains(.control) {
            return false
        }

        switch keyCode {
        case 126: // ↑
            store.moveSelection(-1)
            return true
        case 125: // ↓
            store.moveSelection(1)
            return true
        case 36: // Return
            guard let item = store.selectedItem ?? store.filteredItems.first else { return true }
            if flags.contains(.shift) {
                store.performOCRCopy(for: item)
            } else {
                copyAndPaste(item, store: store)
            }
            return true
        case 49: // Space — Quick Look while nothing is being typed
            guard store.searchText.isEmpty, store.selectedItem != nil else { return false }
            store.toggleQuickLook()
            return true
        default:
            return false
        }
    }
}

private struct ClipboardSettingsView: View {
    let module: ClipboardModule
    @ObservedObject var store: ClipboardStore
    @State private var accessibilityGranted = Permission.accessibility.isGranted

    var body: some View {
        Form {
            Section {
                Toggle("↩로 복사하면 현재 입력 위치에 바로 붙여넣기", isOn: Binding(
                    get: { module.autoPaste },
                    set: { enabled in
                        module.autoPaste = enabled
                        if enabled && !accessibilityGranted { Permission.accessibility.request() }
                    }
                ))
                if module.autoPaste && !accessibilityGranted {
                    LabeledContent {
                        Button("허용하기…") { Permission.accessibility.request() }
                    } label: {
                        Label("붙여넣기에는 손쉬운 사용 권한이 필요합니다", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("붙여넣기")
            } footer: {
                Text("팝오버를 열기 전에 사용하던 앱으로 돌아가 ⌘V를 보냅니다. 클릭이나 ⌘1~0은 복사만 합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TranslationSettingsSection(module: module)
            Section("히스토리") {
                LabeledContent("저장된 항목", value: "\(store.items.count) / \(ClipboardStore.maxItems)")
                LabeledContent("저장 위치") {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.persistence.baseURL])
                    }
                }
                Button("히스토리 전체 삭제", role: .destructive) {
                    store.clearAll()
                }
                .disabled(store.items.isEmpty)
            }
            Section {
                Text("비밀번호 관리자 등이 표시한 민감 데이터(Concealed/Transient/AutoGenerated)는 수집하지 않습니다. 이미지 OCR은 기기 내에서 처리됩니다(한국어·영어).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // TCC has no change notification; poll only while this view is visible.
        .task {
            while !Task.isCancelled {
                accessibilityGranted = Permission.accessibility.isGranted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct TranslationSettingsSection: View {
    let module: ClipboardModule
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var model = ""

    var body: some View {
        Section {
            Picker("엔진", selection: Binding(get: { module.translationEngine }, set: { module.translationEngine = $0 })) {
                ForEach(TranslationEngine.allCases) { Text($0.title).tag($0) }
            }
            engineDetails
            LabeledContent("모델") {
                HStack {
                    TextField("모델", text: $model, prompt: Text(module.translationEngine.defaultModel.isEmpty ? "CLI 기본값" : module.translationEngine.defaultModel))
                        .labelsHidden()
                        .onSubmit { module.setTranslationModel(model, for: module.translationEngine) }
                    if !module.translationEngine.modelSuggestions.isEmpty {
                        Menu("선택") {
                            ForEach(module.translationEngine.modelSuggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    model = suggestion
                                    module.setTranslationModel(suggestion, for: module.translationEngine)
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            Picker("기본 언어", selection: Binding(get: { module.primaryLanguage }, set: { module.primaryLanguage = $0 })) {
                ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
            }
            Picker("상대 언어", selection: Binding(get: { module.secondaryLanguage }, set: { module.secondaryLanguage = $0 })) {
                ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("번역 지침")
                TextEditor(text: Binding(get: { module.translationGuidelines }, set: { module.translationGuidelines = $0 }))
                    .font(.callout)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
                Text("예: 존댓말로 번역, 기술 용어는 영어 그대로 두기")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("이미지를 번역할 때 OCR 텍스트를 클립보드에 저장", isOn: Binding(
                get: { module.savesOCRTextOnTranslate }, set: { module.savesOCRTextOnTranslate = $0 }
            ))
        } header: {
            Text("번역")
        } footer: {
            Text("""
                항목에 마우스를 올리면 나오는 번역 버튼이나 단축키(기본 ⌃⌥T, 클립보드 첫 항목)로 번역합니다. \
                원문이 기본 언어면 상대 언어로, 그 밖의 언어는 기본 언어로 번역합니다. \
                번역할 텍스트는 선택한 API나 CLI의 서비스로 전송됩니다. 모델은 입력 후 Return으로 저장합니다.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onChange(of: module.translationEngine) { refresh() }
    }

    @ViewBuilder
    private var engineDetails: some View {
        let engine = module.translationEngine
        if engine.isCLI {
            if let path = TranslationCLI.executable(for: engine) {
                LabeledContent("CLI", value: path.path)
            } else {
                Label("\(engine.executableName ?? "CLI")을(를) 찾지 못했습니다. 설치한 뒤 터미널에서 한 번 로그인하세요.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            LabeledContent("API 키") {
                HStack {
                    SecureField("API 키", text: $apiKey, prompt: Text(hasKey ? "저장됨 (바꾸려면 새로 입력)" : "키 입력"))
                        .labelsHidden()
                    Button("저장") {
                        TranslationKeychain.setKey(apiKey, for: engine)
                        apiKey = ""
                        refresh()
                    }
                    .disabled(apiKey.isEmpty)
                    if hasKey {
                        Button("삭제", role: .destructive) {
                            TranslationKeychain.setKey("", for: engine)
                            refresh()
                        }
                    }
                }
            }
        }
    }

    private func refresh() {
        hasKey = TranslationKeychain.key(for: module.translationEngine) != nil
        model = module.translationModel(for: module.translationEngine)
        apiKey = ""
    }
}
