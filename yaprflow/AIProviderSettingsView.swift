import SwiftUI

struct AIProviderSettingsView: View {
    @ObservedObject private var settings = AIProviderSettings.shared
    @ObservedObject private var automaticDictation = AutomaticDictationProcessor.shared
    @State private var draftKey = ""
    @State private var statusMessage: String?
    @State private var isTesting = false
    @State private var isLoadingModels = false
    @State private var installedModels: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Provider")
                    .font(.callout.weight(.medium))
                Spacer()
                Picker("AI provider", selection: $settings.provider) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190)
            }

            switch settings.provider {
            case .appleIntelligence:
                Text("When available, Apple Intelligence titles new dictations automatically on this Mac. Requires macOS 26 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .openAI, .openRouter:
                cloudSettings
            case .ollama:
                ollamaSettings
            }

            Divider()

            Toggle("Automatically polish each new dictation", isOn: $settings.automaticDictationOutput)
                .font(.callout)

            Text(settings.provider.sendsTranscriptOffDevice
                 ? "When enabled, each new dictation is sent to \(settings.provider.displayName). The polished version is saved alongside the original; copied text stays unchanged."
                 : "Uses \(settings.provider.displayName) to save a polished version alongside each new dictation. Copied text stays unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Edit the Polished Dictation instructions under Outputs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = automaticDictation.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if settings.provider != .appleIntelligence {
                Divider()

                HStack {
                    Button(isTesting ? "Testing…" : "Test model") { testModel() }
                        .disabled(isTesting || !settings.isConfigured)
                    if isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .onChange(of: settings.provider) { _, _ in
            draftKey = ""
            statusMessage = nil
        }
    }

    private var cloudSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Model ID")
                    .font(.callout)
                    .frame(width: 90, alignment: .leading)
                if settings.provider == .openAI {
                    TextField("e.g. gpt-4o-mini", text: $settings.openAIModel)
                } else {
                    TextField("e.g. openai/gpt-4o-mini", text: $settings.openRouterModel)
                }
            }

            HStack(spacing: 10) {
                Text("API key")
                    .font(.callout)
                    .frame(width: 90, alignment: .leading)
                SecureField(
                    settings.hasKey(for: settings.provider) ? "Saved in Mac Keychain" : "Paste API key",
                    text: $draftKey
                )
                Button("Save key") { saveKey() }
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if settings.hasKey(for: settings.provider) {
                    Button("Remove") { removeKey() }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: settings.hasKey(for: settings.provider) ? "checkmark.shield" : "key")
                Text(settings.hasKey(for: settings.provider)
                     ? "Key saved in this Mac's Keychain."
                     : "Add your own \(settings.provider.displayName) key to use this provider.")
                Spacer()
                if let url = keyPageURL {
                    Link("Get a key", destination: url)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Once configured, new dictations are sent directly from your Mac to \(settings.provider.displayName) for titles. Yaprflow does not relay them through a server.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var ollamaSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Model")
                    .font(.callout)
                    .frame(width: 90, alignment: .leading)
                TextField("Enter an installed model name", text: $settings.ollamaModel)
            }

            HStack(spacing: 10) {
                Button(isLoadingModels ? "Checking…" : "Find installed models") {
                    loadInstalledModels()
                }
                .disabled(isLoadingModels)

                if !installedModels.isEmpty {
                    Menu("Choose model") {
                        ForEach(installedModels, id: \.self) { model in
                            Button(model) { settings.ollamaModel = model }
                        }
                    }
                }
                if isLoadingModels { ProgressView().controlSize(.small) }
                Spacer()
            }

            Text("Once configured, Ollama automatically titles new dictations at localhost:11434. Local models stay on this Mac; cloud models follow Ollama's policy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var keyPageURL: URL? {
        switch settings.provider {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .openRouter: URL(string: "https://openrouter.ai/settings/keys")
        case .appleIntelligence, .ollama: nil
        }
    }

    private func saveKey() {
        do {
            try settings.saveKey(draftKey, for: settings.provider)
            draftKey = ""
            statusMessage = "API key saved."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try settings.removeKey(for: settings.provider)
            draftKey = ""
            statusMessage = "API key removed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func testModel() {
        isTesting = true
        statusMessage = nil
        Task {
            defer { isTesting = false }
            do {
                let configuration = try settings.configuration()
                _ = try await AIChatClient().complete(
                    configuration: configuration,
                    instructions: "Reply briefly and plainly.",
                    prompt: "Reply with OK.",
                    maximumResponseTokens: 80
                )
                statusMessage = "Connected to \(configuration.provider.displayName) using \(configuration.model)."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func loadInstalledModels() {
        isLoadingModels = true
        statusMessage = nil
        Task {
            defer { isLoadingModels = false }
            do {
                installedModels = try await AIChatClient().installedOllamaModels()
                statusMessage = installedModels.isEmpty
                    ? "No installed Ollama models found. Install one with Ollama, then check again."
                    : "Found \(installedModels.count) installed model\(installedModels.count == 1 ? "" : "s")."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
