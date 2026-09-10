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
