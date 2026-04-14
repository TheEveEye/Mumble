import SwiftUI

struct ServerPasswordPromptContext: Identifiable, Equatable {
    let id: UUID
    let serverID: UUID
    let serverLabel: String
    let failureReason: String?
    let rememberByDefault: Bool
}

struct ServerPasswordPrompt: View {
    let context: ServerPasswordPromptContext
    let onSubmit: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var rememberPassword: Bool

    init(
        context: ServerPasswordPromptContext,
        onSubmit: @escaping (String, Bool) -> Void
    ) {
        self.context = context
        self.onSubmit = onSubmit
        _rememberPassword = State(initialValue: context.rememberByDefault)
    }

    private var canSubmit: Bool {
        !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Enter the password for \(context.serverLabel).")
                    .fixedSize(horizontal: false, vertical: true)

                if let failureReason = context.failureReason, !failureReason.isEmpty {
                    Text(failureReason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                Toggle("Remember in Keychain", isOn: $rememberPassword)

                HStack {
                    Spacer()

                    Button("Cancel") {
                        dismiss()
                    }

                    Button("Connect") {
                        onSubmit(password, rememberPassword)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                }
            }
            .padding()
            .navigationTitle("Server Password")
            .frame(minWidth: 360)
        }
    }
}
