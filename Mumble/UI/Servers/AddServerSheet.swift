import SwiftUI
import SwiftData

struct AddServerSheet: View {
    let logger: AppLogger
    let server: SavedServer?
    let onSave: ((SavedServer) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var host = ""
    @State private var port = "64738"
    @State private var username = ""

    init(
        logger: AppLogger,
        server: SavedServer? = nil,
        onSave: ((SavedServer) -> Void)? = nil
    ) {
        self.logger = logger
        self.server = server
        self.onSave = onSave
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: String(server?.port ?? 64738))
        _username = State(initialValue: server?.username ?? "")
    }

    private var parsedPort: Int {
        Int(port) ?? 64738
    }

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEditing: Bool {
        server != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    EditorRow(title: "Address") {
                        TextField("127.0.0.1", text: $host)
                            .textFieldStyle(.roundedBorder)
                    }

                    EditorRow(title: "Port") {
                        TextField("64738", text: $port)
                            .textFieldStyle(.roundedBorder)
                    }

                    EditorRow(title: "Username") {
                        TextField("BRAVE - SomeKiwi", text: $username)
                            .textFieldStyle(.roundedBorder)
                    }

                    EditorRow(title: "Label") {
                        TextField("Local server label", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Spacer()

                    Button("Cancel") {
                        dismiss()
                    }

                    Button("OK") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }
            }
            .padding()
            .navigationTitle(isEditing ? "Edit Server" : "Add Server")
            .frame(minWidth: 460, minHeight: 220)
        }
    }

    private func save() {
        let persistedServer: SavedServer

        if let server {
            server.update(
                name: name,
                folderName: server.folderName,
                host: host,
                port: parsedPort,
                username: username,
                note: server.note,
                isFavorite: server.isFavorite
            )
            persistedServer = server
        } else {
            let server = SavedServer(
                name: name,
                host: host,
                port: parsedPort,
                username: username
            )
            modelContext.insert(server)
            persistedServer = server
        }

        do {
            try modelContext.save()
            logger.info("Saved server \(persistedServer.displayName)")
            onSave?(persistedServer)
            dismiss()
        } catch {
            logger.error("Failed to save server: \(error.localizedDescription)")
        }
    }
}

private struct EditorRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .frame(width: 82, alignment: .leading)

            content
        }
    }
}
