import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var aiSettings = AIProviderSettings.shared
    @ObservedObject private var telemetry = Telemetry.shared
    #if DIRECT_DISTRIBUTION
    @ObservedObject private var updater = AppUpdater.shared
    #endif
    @State private var isShowingFeedback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FeatureWindowHeader(
                    symbolName: "gearshape.fill",
                    title: "Settings",
                    subtitle: "Control Yaprflow and review how your data is handled.",
                    accent: .blue,
                    badge: "Your choice",
                    badgeSymbol: "slider.horizontal.3"
                )

                FeatureCard {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speech language")
                                    .font(.callout.weight(.medium))
                                Text(speechLanguageDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

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
                        .padding(.vertical, 10)

                        Divider().padding(.leading, 38)

                        HStack(spacing: 12) {
                            Image(systemName: appState.isDesktopPreviewEnabled ? "eye" : "eye.slash")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Desktop preview")
                                    .font(.callout.weight(.medium))
                                Text("Show the floating transcript while recording.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Toggle("Desktop preview", isOn: desktopPreviewBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(.vertical, 10)
                    }
                }

                FeatureCard {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "mic")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quick Dictation")
                                    .font(.callout.weight(.medium))
                                Text("Start or stop dictation from any app.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            HotkeyRecorder(hotkey: appState.hotkey)
                                .frame(width: 118, height: 28)
                        }
                        .padding(.vertical, 8)

                        Divider().padding(.leading, 38)

                        HStack(spacing: 12) {
                            Image(systemName: "person.2.wave.2")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Meeting Notes")
                                    .font(.callout.weight(.medium))
                                Text("Open Meeting Notes from any app.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(HotkeyConfig.meetingNotesHotkey.displayString)
                                .font(.callout.monospaced())
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("Meeting Notes shortcut Command M")
                        }
                        .padding(.vertical, 8)
                    }
                }

                FeatureCard {
                    AIProviderSettingsView()
                }

                FeatureCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "chart.bar.xaxis")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)
                            Text("Share anonymous usage and error counts")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Toggle("Share anonymous usage and error counts", isOn: $telemetry.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!telemetry.isConfigured && !telemetry.isEnabled)
                        }
                        Text(telemetry.isConfigured
                             ? "On by default. Helps us see app launches, feature use, and broad failure categories by app and macOS version. No audio, transcript text, prompts, feedback messages, or app names are included. Turn this off at any time."
                             : "Telemetry is not configured in this build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 38)
                    }
                }

                FeatureCard {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .foregroundStyle(.secondary)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Send feedback")
                                .font(.callout.weight(.medium))
                            Text("Report a problem, ask a question, or suggest an improvement.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Button("Send Feedback…") {
                            Telemetry.shared.track(.featureOpened(.feedback))
                            isShowingFeedback = true
                        }
                        .buttonStyle(.bordered)
                    }
                }

                FeatureCard {
                    VStack(spacing: 0) {
                        PrivacyRow(
                            symbol: "waveform",
                            title: "Speech recognition",
                            detail: "Processed locally with Nemotron and sherpa-onnx",
                            status: "On-device"
                        )
                        Divider().padding(.leading, 38)
                        PrivacyRow(
                            symbol: "sparkles",
                            title: "AI features",
                            detail: aiPrivacyDetail,
                            status: aiSettings.provider == .ollama
                                ? "Ollama"
                                : (aiSettings.provider.sendsTranscriptOffDevice ? "Cloud" : "Local")
                        )
                        Divider().padding(.leading, 38)
                        PrivacyRow(
                            symbol: "person.crop.circle.badge.xmark",
                            title: "Accounts",
                            detail: "No Yaprflow account or sign-in required",
                            status: "None"
                        )
                        Divider().padding(.leading, 38)
                        PrivacyRow(
                            symbol: "chart.bar.xaxis",
                            title: "Telemetry",
                            detail: "Anonymous usage and error counts only",
                            status: telemetry.isConfigured
                                ? (telemetry.isEnabled ? "On" : "Off")
                                : "Unavailable"
                        )
                    }
                }

                FeatureCard {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Version")
                                    .font(.callout.weight(.medium))
                                Text("Your installed Yaprflow version.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(appVersion)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            #if DIRECT_DISTRIBUTION
                            Button("Check Now") {
                                updater.checkForUpdates()
                            }
                            .buttonStyle(.bordered)
                            #endif
                        }
                        .padding(.vertical, 10)

                        #if DIRECT_DISTRIBUTION
                        Divider().padding(.leading, 38)

                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatically check for updates")
                                    .font(.callout.weight(.medium))
                                Text("Check the signed Yaprflow release feed once a day.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Toggle("Automatically check for updates", isOn: automaticUpdateChecksBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(.vertical, 10)
                        #else
                        Divider().padding(.leading, 38)

                        HStack(spacing: 12) {
                            Image(systemName: "storefront")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("App updates")
                                    .font(.callout.weight(.medium))
                                Text("Updates for this edition are delivered automatically by the Mac App Store.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text("Mac App Store")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                        #endif

                        #if DIRECT_DISTRIBUTION
                        Divider().padding(.leading, 38)

                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.app")
                                .foregroundStyle(.secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatically download updates")
                                    .font(.callout.weight(.medium))
                                Text("Install verified updates when Yaprflow is ready to relaunch.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Toggle("Automatically download updates", isOn: automaticUpdateDownloadsBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!updater.automaticallyChecksForUpdates)
                        }
                        .padding(.vertical, 10)
                        #endif

                        Divider().padding(.leading, 38)

                        HStack(spacing: 20) {
                            Link(destination: URL(string: "https://yaprflow.com/privacy.html")!) {
                                Label("Privacy Policy", systemImage: "hand.raised")
                            }

                            Button {
                                AcknowledgementsWindowController.show()
                            } label: {
                                Label("Acknowledgements", systemImage: "doc.text")
                            }
                            .buttonStyle(.link)

                            Spacer()
                        }
                        .font(.caption.weight(.medium))
                        .padding(.top, 12)
                    }
                }

            }
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShowingFeedback) {
            FeedbackView()
                .frame(minWidth: 620, minHeight: 600)
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

    private var aiPrivacyDetail: String {
        switch aiSettings.provider {
        case .appleIntelligence:
            "Uses Apple's on-device model"
        case .openAI, .openRouter:
            "Sends AI requests to \(aiSettings.provider.displayName) when you run them"
        case .ollama:
            "Uses Ollama at localhost:11434"
        }
    }

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
            return "Detect a language for each speech segment."
        case .englishUS, .englishUK:
            return "Keep recognition in English for more reliable short dictation."
        default:
            return "Keep recognition in the selected language for better accuracy."
        }
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

private struct PrivacyRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }
}
