import AppKit
import Combine
import SwiftUI

enum AppPanelTab: Hashable {
    case aiSummary
    case history
    case settings
}

@MainActor
private final class AppPanelSelection: ObservableObject {
    @Published var selectedTab: AppPanelTab = .aiSummary
}

private struct AppPanelView: View {
    @ObservedObject var selection: AppPanelSelection
    @State private var isVisible = false

    var body: some View {
        TabView(selection: $selection.selectedTab) {
            TranscriptAIView()
                .tabItem {
                    Label("AI Summary", systemImage: "sparkles")
                }
                .tag(AppPanelTab.aiSummary)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppPanelTab.history)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppPanelTab.settings)
        }
        .frame(minWidth: 620, minHeight: 600)
        .onAppear {
            isVisible = true
            Telemetry.shared.track(.featureOpened(telemetryFeature(for: selection.selectedTab)))
        }
        .onDisappear { isVisible = false }
        .onChange(of: selection.selectedTab) { _, tab in
            if isVisible {
                Telemetry.shared.track(.featureOpened(telemetryFeature(for: tab)))
            }
        }
    }

    private func telemetryFeature(for tab: AppPanelTab) -> TelemetryFeature {
        switch tab {
        case .aiSummary: .aiSummary
        case .history: .history
        case .settings: .settings
        }
    }
}

@MainActor
enum AppPanelWindowController {
    private static let selection = AppPanelSelection()
    private static let window = FeatureWindowController(
        title: "Yaprflow",
        contentSize: NSSize(width: 660, height: 640),
        minimumSize: NSSize(width: 620, height: 600)
    ) {
        AppPanelView(selection: selection)
    }

    static func show(_ tab: AppPanelTab) {
        selection.selectedTab = tab
        window.show()
    }
}
