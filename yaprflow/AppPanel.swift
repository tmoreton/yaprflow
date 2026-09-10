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
