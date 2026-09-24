import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var telemetry = Telemetry.shared
    #if DIRECT_DISTRIBUTION
    @ObservedObject private var updater = AppUpdater.shared
    #endif
    @State private var isShowingFeedback = false
    @State private var showsAdvancedSettings = false
    @State private var errorMessage: String?
    @State private var hasAccessibilityAccess = InputAutomation.hasAccessibilityAccess
    @State private var hasPostEventAccess = InputAutomation.hasPostEventAccess

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsGroup("General") {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            settingLabel("Desktop preview", detail: "Show finalized text after each pause.")
                            Spacer(minLength: 16)
                            Toggle("Desktop preview", isOn: desktopPreviewBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(.vertical, 9)

                        Divider()

                        HStack(spacing: 12) {
                            settingLabel(
                                "Auto-paste",
                                detail: autoPasteDetail
                            )
                            Spacer(minLength: 16)
                            VStack(alignment: .trailing, spacing: 4) {
                                Toggle("Auto-paste", isOn: autoPasteBinding)
                                    .labelsHidden()
                                    .toggleStyle(.switch)

                                if appState.isAutoPasteEnabled && !hasPostEventAccess {
                                    Button("Allow Access") {
                                        InputAutomation.requestPostEventAccess()
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 9)

                        Divider()

                        HStack(spacing: 12) {
                            settingLabel(
                                "Copied text",
                                detail: "Polished applies local cleanup; Exact keeps the recognized wording."
                            )
                            Spacer(minLength: 16)
                            Picker("Copied text style", selection: $appState.dictationMode) {
                                ForEach(DictationMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 118)
                        }
                        .padding(.vertical, 9)

                        Divider()

                        HStack(spacing: 12) {
                            settingLabel("Dictation", detail: dictationShortcutDetail)
                            Spacer(minLength: 16)
                            VStack(alignment: .trailing, spacing: 4) {
                                HotkeyRecorder(hotkey: appState.hotkey)
                                    .frame(width: 118, height: 28)

                                if appState.hotkey.isModifierOnly && !hasAccessibilityAccess {
                                    Button("Allow Access") {
                                        InputAutomation.requestAccessibilityAccess()
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 9)

                        Divider()

                        HStack(spacing: 12) {
                            settingLabel(
                                "Vocabulary",
                                detail: "Teach Yaprflow names, acronyms, and preferred spellings."
                            )
                            Spacer(minLength: 16)
                            Button("Open File") {
                                openVocabularyFile()
                            }
                        }
                        .padding(.vertical, 9)
                    }
                }

                settingsGroup("AI") {
                    AIProviderSettingsView()
                }

                DisclosureGroup(isExpanded: $showsAdvancedSettings) {
                    FeatureCard {
                        PromptPresetSettingsView()
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced")
                        .font(.headline)
                }

                settingsGroup("Privacy") {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 12) {
                            Text("Share anonymous usage counts")
                                .font(.callout.weight(.medium))
                            Spacer(minLength: 16)
                            Toggle("Share anonymous usage counts", isOn: $telemetry.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!telemetry.isConfigured && !telemetry.isEnabled)
                        }

                        Text(telemetry.isConfigured
                             ? "Includes feature and broad error counts—never audio, transcript text, prompts, or app names."
                             : "Telemetry is not included in this build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }

                settingsGroup("Updates") {
                    updateSettings
                }

                HStack(spacing: 18) {
                    Button("Send feedback") {
                        Telemetry.shared.track(.featureOpened(.feedback))
                        isShowingFeedback = true
                    }
                    .buttonStyle(.link)

                    if let privacyURL = URL(string: "https://yaprflow.com/privacy.html") {
                        Link("Privacy", destination: privacyURL)
                    }

                    Button("Acknowledgements") {
                        AcknowledgementsWindowController.show()
                    }
                    .buttonStyle(.link)

                    Spacer()
                }
                .font(.caption)
            }
            .padding(22)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            hasAccessibilityAccess = InputAutomation.hasAccessibilityAccess
            hasPostEventAccess = InputAutomation.hasPostEventAccess
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibilityAccess = InputAutomation.hasAccessibilityAccess
            hasPostEventAccess = InputAutomation.hasPostEventAccess
        }
        .sheet(isPresented: $isShowingFeedback) {
            FeedbackView()
                .frame(minWidth: 620, minHeight: 600)
        }
        .alert(
            "Couldn’t open vocabulary",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            FeatureCard {
                content()
            }
        }
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var autoPasteDetail: String {
        if appState.isAutoPasteEnabled && !hasPostEventAccess {
            return "Accessibility access is required to paste at the current cursor."
        }
        return "Paste finished dictation at the current cursor after copying it."
    }

    private var dictationShortcutDetail: String {
        if appState.hotkey.isModifierOnly && !hasAccessibilityAccess {
            return "Accessibility access is required for a modifier-only shortcut."
        }
        return "Start or stop from any app; a modifier can be used by itself."
    }

    private var autoPasteBinding: Binding<Bool> {
        Binding(
            get: { appState.isAutoPasteEnabled },
            set: { isEnabled in
                appState.isAutoPasteEnabled = isEnabled
                if isEnabled {
                    InputAutomation.requestPostEventAccess()
                    hasPostEventAccess = InputAutomation.hasPostEventAccess
                }
            }
        )
    }

    @ViewBuilder
    private var updateSettings: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(appVersion)")
                        .font(.callout.weight(.medium))
                    #if !DIRECT_DISTRIBUTION
                    Text("Updates are installed through the Mac App Store.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }
                Spacer()
                #if DIRECT_DISTRIBUTION
                Button("Check Now") {
                    updater.checkForUpdates()
                }
                .accessibilityLabel("Check for updates now")
                .disabled(!updater.canCheckForUpdates)
                #endif
            }
            .padding(.vertical, 9)

            #if DIRECT_DISTRIBUTION
            Divider()

            Toggle(isOn: automaticUpdatesBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic updates")
                        .font(.callout.weight(.medium))
                    Text("Check for and download new versions automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.vertical, 9)
            #endif
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let version else { return "Unknown" }
        return build.map { "\(version) (\($0))" } ?? version
    }

    #if DIRECT_DISTRIBUTION
    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(
            get: {
                updater.automaticallyChecksForUpdates
                    && updater.automaticallyDownloadsUpdates
            },
            set: { enabled in
                if enabled {
                    updater.setAutomaticallyChecksForUpdates(true)
                    updater.setAutomaticallyDownloadsUpdates(true)
                } else {
                    updater.setAutomaticallyDownloadsUpdates(false)
                    updater.setAutomaticallyChecksForUpdates(false)
                }
            }
        )
    }
    #endif

    private var desktopPreviewBinding: Binding<Bool> {
        Binding(
            get: { appState.isDesktopPreviewEnabled },
            set: { appState.isDesktopPreviewEnabled = $0 }
        )
    }

    private func openVocabularyFile() {
        do {
            NSWorkspace.shared.open(try appState.vocabularyFileURL())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

@MainActor
enum SettingsWindowController {
    private static let window = FeatureWindowController(
        title: "Settings",
        contentSize: NSSize(width: 780, height: 700),
        minimumSize: NSSize(width: 640, height: 520),
        usesTransparentTitlebar: false
    ) {
        SettingsView()
    }

    static func show() {
        Telemetry.shared.track(.featureOpened(.settings))
        window.show()
    }

    static var isVisibleForSmokeTest: Bool { window.isVisibleForSmokeTest }
    static var isKeyForSmokeTest: Bool { window.isKeyForSmokeTest }
}

private struct PromptPresetSettingsView: View {
    @State private var selectedPresetID = LibraryPromptCatalog.structuredBrief.id
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output prompts")
                        .font(.callout.weight(.medium))
                    Text("Meeting notes and dictations; Polished Dictation is dictation-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Picker("Output prompt", selection: $selectedPresetID) {
                    ForEach(LibraryPromptCatalog.dictationPresets) { preset in
                        Label(preset.title, systemImage: preset.systemImage).tag(preset.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190)
            }

            TextEditor(text: promptBinding)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 130, maxHeight: 180)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator, lineWidth: 1)
                }
                .accessibilityLabel("\(selectedPreset.title) prompt")

            HStack {
                Text("Changes save automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Default") {
                    LibraryPromptPreferences.reset(presetID: selectedPreset.id)
                    prompt = selectedPreset.prompt
                    notifyPromptChange()
                }
            }
        }
        .padding(.vertical, 5)
        .onAppear(perform: loadPrompt)
        .onChange(of: selectedPresetID) { _, _ in loadPrompt() }
    }

    private var selectedPreset: LibraryPromptPreset {
        LibraryPromptCatalog.itemPreset(id: selectedPresetID)
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { prompt },
            set: { newValue in
                prompt = newValue
                LibraryPromptPreferences.setPrompt(newValue, for: selectedPreset.id)
                notifyPromptChange()
            }
        )
    }

    private func loadPrompt() {
        let preset = LibraryPromptCatalog.itemPreset(id: selectedPresetID)
        selectedPresetID = preset.id
        prompt = LibraryPromptPreferences.prompt(for: preset.id)
    }

    private func notifyPromptChange() {
        NotificationCenter.default.post(name: .yaprflowPromptPresetsChanged, object: nil)
    }
}

@MainActor
private enum AcknowledgementsWindowController {
    private static let window = FeatureWindowController(
        title: "Acknowledgements",
        contentSize: NSSize(width: 640, height: 620),
        minimumSize: NSSize(width: 520, height: 420)
    ) {
        AcknowledgementsView()
    }

    static func show() {
        window.show()
    }
}

private struct AcknowledgementsView: View {
    private let contents: String = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Acknowledgements could not be loaded."
        }
        return text
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FeatureWindowHeader(
                symbolName: "doc.text.fill",
                title: "Acknowledgements",
                subtitle: "Third-party software and model licenses bundled with Yaprflow.",
                accent: .blue,
                badge: "Licenses",
                badgeSymbol: "checkmark.seal.fill"
            )

            ScrollView {
                Text(contents)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
