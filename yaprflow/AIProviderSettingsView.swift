import SwiftUI

struct AIProviderSettingsView: View {
    @ObservedObject private var settings = AIProviderSettings.shared
    @State private var draftKey = ""
    @State private var statusMessage: String?
    @State private var isTesting = false
    @State private var isLoadingModels = false
    @State private var installedModels: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI provider")
                        .font(.callout.weight(.medium))
                    Text("Choose what runs meeting summaries, transcript tools, and automatic titles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            Divider()

            switch settings.provider {
            case .appleIntelligence:
                Text("Runs on supported Macs with Apple Intelligence enabled. Meeting and dictation transcripts stay on this device when using AI features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .openAI, .openRouter:
                cloudSettings
            case .ollama:
                ollamaSettings
            }

            if settings.provider != .appleIntelligence {
                Divider()

                Toggle("Generate archive titles automatically", isOn: $settings.automaticRemoteMetadata)
                    .font(.callout)

                Text(settings.provider.sendsTranscriptOffDevice
                     ? "Off by default. When enabled, each new transcript is sent to \(settings.provider.displayName) to create its title, topic, and description."
                     : "Off by default. When enabled, Ollama creates titles for new transcripts on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Text("Using meeting summaries or transcript tools sends the selected text and instructions to \(settings.provider.displayName). Your provider may charge for requests. Yaprflow does not receive your key or transcript.")
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

            Text("Uses Ollama at localhost:11434 on this Mac. Start Ollama and install a model first. Local models stay on this Mac; Ollama cloud models may send requests to Ollama's service.")
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
