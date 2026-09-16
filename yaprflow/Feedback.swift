import AppKit
import SwiftUI

private enum FeedbackKind: String, CaseIterable, Identifiable {
    case problem = "Problem"
    case suggestion = "Suggestion"
    case question = "Question"

    var id: Self { self }
}

struct FeedbackView: View {
    @State private var kind: FeedbackKind = .problem
    @State private var subject = ""
    @State private var message = ""
    @State private var mailUnavailable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FeatureWindowHeader(
                    symbolName: "bubble.left.and.text.bubble.right.fill",
                    title: "Send Feedback",
                    subtitle: "Tell us what happened or what you would like to see.",
                    accent: .blue,
                    badge: "Email",
                    badgeSymbol: "envelope"
                )

                FeatureCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Type", selection: $kind) {
                            ForEach(FeedbackKind.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }

                        TextField("Short summary", text: $subject)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Feedback summary")

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Details")
                                .font(.callout.weight(.medium))
                            TextEditor(text: $message)
                                .font(.body)
                                .frame(minHeight: 170)
                                .scrollContentBackground(.hidden)
                                .padding(5)
                                .background(
                                    Color(nsColor: .textBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .accessibilityLabel("Feedback details")
                        }

                        Text("Your email app will open a draft for you to review and send. The draft includes your message, Yaprflow version, and macOS version. It does not include a transcript or recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Spacer()
                            Button("Continue in Mail") { composeEmail() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!canCompose)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Email app unavailable", isPresented: $mailUnavailable) {
            Button("Copy message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(emailBody, forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Copy your message and email it to tim@yaprflow.com when an email app is available.")
        }
    }

    private var canCompose: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emailSubject: String {
        "Yaprflow \(kind.rawValue): \(subject.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private var emailBody: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return """
        Type: \(kind.rawValue)
        Summary: \(subject.trimmingCharacters(in: .whitespacesAndNewlines))

        \(message.trimmingCharacters(in: .whitespacesAndNewlines))

        ---
        Yaprflow \(version) (\(build))
        \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
    }

    private func composeEmail() {
        if let service = NSSharingService(named: .composeEmail),
            service.canPerform(withItems: [emailBody]) {
            service.recipients = ["tim@yaprflow.com"]
            service.subject = emailSubject
            service.perform(withItems: [emailBody])
            Telemetry.shared.track(.feedbackDraftOpened)
            return
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "tim@yaprflow.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: emailSubject),
            URLQueryItem(name: "body", value: emailBody),
        ]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            mailUnavailable = true
            return
        }
        Telemetry.shared.track(.feedbackDraftOpened)
    }
}
