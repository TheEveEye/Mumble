import SwiftUI

struct ServerCertificateTrustPrompt: View {
    let challenge: MumbleCertificateTrustChallenge
    let onDecision: (Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rememberCertificate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trust Certificate")
                .font(.title3.weight(.semibold))

            Text("Mumble could not automatically verify the certificate for `\(challenge.endpointDescription)`.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                trustRow("Server", value: challenge.serverLabel)
                trustRow("Endpoint", value: challenge.endpointDescription)
                trustRow("Common Name", value: challenge.commonName.isEmpty ? "Unavailable" : challenge.commonName)
                trustRow("Subject", value: challenge.subjectSummary.isEmpty ? "Unavailable" : challenge.subjectSummary)
                trustRow("Fingerprint", value: challenge.formattedFingerprint)
                trustRow("Reason", value: challenge.failureDescription)
            }

            Toggle("Always trust this certificate for this server", isOn: $rememberCertificate)

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                    onDecision(false, false)
                }

                Button("Trust") {
                    dismiss()
                    onDecision(true, rememberCertificate)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func trustRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
