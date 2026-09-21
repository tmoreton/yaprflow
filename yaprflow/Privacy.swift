import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var telemetry = Telemetry.shared
    #if DIRECT_DISTRIBUTION
    @ObservedObject private var updater = AppUpdater.shared
    #endif
    @State private var isShowingFeedback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))
                    Text("The essentials for dictation, meetings, and AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                settingsGroup("General") {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            settingLabel("Speech language", detail: speechLanguageDetail)
                            Spacer(minLength: 16)
                            Picker("Speech language", selection: speechLanguageBinding) {
                                ForEach(SpeechLanguage.allCases) { language in
                                    Text(language.displayName).tag(language)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 190)
                            .accessibilityLabel("Speech language")
                        }
                        .padding(.vertical, 9)

                        Divider()

                        HStack(spacing: 12) {
                            settingLabel("Desktop preview", detail: "Show live text while dictating.")
                            Spacer(minLength: 16)
                            Toggle("Desktop preview", isOn: desktopPreviewBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(.vertical, 9)

                        Divider()

                        HStack(spacing: 12) {
                            settingLabel("Quick Dictation", detail: "Start or stop from any app.")
                            Spacer(minLength: 16)
                            HotkeyRecorder(hotkey: appState.hotkey)
                                .frame(width: 118, height: 28)
                        }
                        .padding(.vertical, 9)

                        Divider()

                        HStack(spacing: 12) {
                            settingLabel("Meetings", detail: "Open the meeting workspace.")
                            Spacer(minLength: 16)
                            Text(HotkeyConfig.meetingNotesHotkey.displayString)
                                .font(.callout.monospaced())
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("Meetings shortcut Command M")
                        }
                        .padding(.vertical, 9)
                    }
                }

                settingsGroup("AI") {
                    AIProviderSettingsView()
                }

                settingsGroup("Outputs") {
                    PromptPresetSettingsView()
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

                    Link("Privacy", destination: URL(string: "https://yaprflow.com/privacy.html")!)

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
        .sheet(isPresented: $isShowingFeedback) {
            FeedbackView()
                .frame(minWidth: 620, minHeight: 600)
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

    @ViewBuilder
    private var updateSettings: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Installed version")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(appVersion)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Installed version \(appVersion)")
            }
            .padding(.vertical, 7)

            Divider()

        #if DIRECT_DISTRIBUTION
            HStack {
                Text("Check for updates")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Check Now") {
                    updater.checkForUpdates()
                }
            }
            .padding(.vertical, 7)

            Divider()

            Toggle("Check automatically", isOn: automaticUpdateChecksBinding)
                .padding(.vertical, 9)

            Divider()

            Toggle("Download automatically", isOn: automaticUpdateDownloadsBinding)
                .padding(.vertical, 9)
                .disabled(!updater.automaticallyChecksForUpdates)
        #else
            HStack {
                Text("Updates are installed automatically through the Mac App Store.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Mac App Store")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
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
    private var automaticUpdateChecksBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        )
    }

    private var automaticUpdateDownloadsBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.setAutomaticallyDownloadsUpdates($0) }
        )
    }
    #endif

    private var desktopPreviewBinding: Binding<Bool> {
        Binding(
            get: { appState.isDesktopPreviewEnabled },
            set: { appState.isDesktopPreviewEnabled = $0 }
        )
    }

    private var speechLanguageBinding: Binding<SpeechLanguage> {
        Binding(
            get: { appState.speechLanguage },
            set: { appState.speechLanguage = $0 }
        )
    }

    private var speechLanguageDetail: String {
        switch appState.speechLanguage {
        case .automatic:
            "Detect each speech segment."
        case .englishUS, .englishUK:
            "Keep recognition in English."
        default:
            "Keep recognition in the selected language."
        }
    }
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
                    Text("Used for both meeting notes and dictations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Picker("Output prompt", selection: $selectedPresetID) {
                    ForEach(LibraryPromptCatalog.itemPresets) { preset in
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
