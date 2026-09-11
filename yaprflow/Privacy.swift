import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FeatureWindowHeader(
                symbolName: "gearshape.fill",
                title: "Settings",
                subtitle: "Control Yaprflow and review how your data is handled.",
                accent: .blue,
                badge: "On-device",
                badgeSymbol: "lock.fill"
            )

            FeatureCard {
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
            }

            FeatureCard {
                HStack(spacing: 12) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyboard shortcut")
                            .font(.callout.weight(.medium))
                        Text("Start or stop dictation from any app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HotkeyRecorder(hotkey: appState.hotkey)
                        .frame(width: 118, height: 28)
                }
            }

            FeatureCard {
                VStack(spacing: 0) {
                    PrivacyRow(
                        symbol: "waveform",
                        title: "Speech recognition",
                        detail: "Processed with local Core ML models",
                        status: "On-device"
                    )
                    Divider().padding(.leading, 38)
                    PrivacyRow(
                        symbol: "sparkles",
                        title: "AI Summary",
                        detail: "Uses Apple's on-device model",
                        status: "On-device"
                    )
                    Divider().padding(.leading, 38)
                    PrivacyRow(
                        symbol: "person.crop.circle.badge.xmark",
                        title: "Accounts",
                        detail: "No account or sign-in required",
                        status: "None"
                    )
                    Divider().padding(.leading, 38)
                    PrivacyRow(
                        symbol: "chart.bar.xaxis",
                        title: "Telemetry",
                        detail: "No analytics or transcript data sent",
                        status: "Off"
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
                    }
                    .padding(.vertical, 10)

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

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var desktopPreviewBinding: Binding<Bool> {
        Binding(
            get: { appState.isDesktopPreviewEnabled },
            set: { appState.isDesktopPreviewEnabled = $0 }
        )
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
                subtitle: "Open-source software and model licenses bundled with Yaprflow.",
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
