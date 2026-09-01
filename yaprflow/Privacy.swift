import AppKit
import SwiftUI

struct PrivacyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FeatureWindowHeader(
                symbolName: "lock.shield.fill",
                title: "Privacy",
                subtitle: "Your voice and transcripts stay on this Mac.",
                accent: .green,
                badge: "Local only",
                badgeSymbol: "lock.fill"
            )

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
                        title: "AI Actions",
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
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcript storage")
                            .font(.callout.weight(.medium))
                        Text("Saved as Markdown files in Application Support.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("View History") {
                        HistoryWindowController.shared.show()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(minWidth: 540, minHeight: 400)
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

@MainActor
enum PrivacyWindowController {
    static let shared = FeatureWindowController(
        title: "Privacy",
        contentSize: NSSize(width: 580, height: 430),
        minimumSize: NSSize(width: 540, height: 400)
    ) {
        PrivacyView()
    }
}
