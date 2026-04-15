import SwiftData
import SwiftUI

struct ConnectServerDialog: View {
    let logger: AppLogger
    let serverStatus: MumbleServerStatusService
    @Binding var selectedServerID: UUID?
    let onConnect: (SavedServer) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(animation: .default) private var servers: [SavedServer]

    @State private var isPresentingServerEditor = false
    @State private var editingServerID: UUID?

    private var refreshTargets: [ServerRefreshTarget] {
        SavedServerPresentation.sorted(servers).map {
            ServerRefreshTarget(id: $0.id, host: $0.host, port: $0.port)
        }
    }

    private var sections: [SavedServerSection] {
        SavedServerPresentation.sections(from: servers)
    }

    private var selectedServer: SavedServer? {
        guard let selectedServerID else {
            return nil
        }

        return servers.first(where: { $0.id == selectedServerID })
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Connect to a Server")
                .font(.title3)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                HeaderRow()

                if sections.isEmpty {
                    EmptySavedServersView()
                } else {
                    List(selection: $selectedServerID) {
                        ForEach(sections) { section in
                            if section.title == "Servers" {
                                ForEach(section.servers) { server in
                                    ServerRow(server: server)
                                        .tag(server.id)
                                }
                            } else {
                                Section(section.title) {
                                    ForEach(section.servers) { server in
                                        ServerRow(server: server)
                                            .tag(server.id)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("Add New") {
                    editingServerID = nil
                    isPresentingServerEditor = true
                }

                Button("Edit") {
                    editingServerID = selectedServer?.id
                    isPresentingServerEditor = selectedServer != nil
                }
                .disabled(selectedServer == nil)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Connect") {
                    guard let selectedServer else {
                        return
                    }

                    connect(selectedServer)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedServer == nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: 430)
        .task(id: servers.count) {
            ensureValidSelection()
        }
        .task(id: refreshTargets) {
            await refreshServerStatuses()
        }
        .sheet(isPresented: $isPresentingServerEditor) {
            AddServerSheet(
                logger: logger,
                server: editingServerID.flatMap { serverID in
                    servers.first(where: { $0.id == serverID })
                }
            ) { savedServer in
                selectedServerID = savedServer.id
            }
        }
    }

    private func ensureValidSelection() {
        guard !servers.isEmpty else {
            selectedServerID = nil
            return
        }

        if let selectedServerID, servers.contains(where: { $0.id == selectedServerID }) {
            return
        }

        selectedServerID = SavedServerPresentation.sorted(servers).first?.id
    }

    private func connect(_ server: SavedServer) {
        logger.info("Selected server \(server.displayName) for connection")
        onConnect(server)
        dismiss()
    }

    private func refreshServerStatuses() async {
        let targets = refreshTargets.map {
            MumbleServerPingTarget(id: $0.id, host: $0.host, port: $0.port)
        }

        guard !targets.isEmpty else {
            return
        }

        let statuses = await serverStatus.fetchStatuses(for: targets)
        var shouldSave = false

        for server in servers {
            let status = statuses[server.id] ?? nil
            let pingMilliseconds = status?.pingMilliseconds
            let userCount = status?.userCount
            let maximumUserCount = status?.maximumUserCount

            guard server.lastKnownPingMilliseconds != pingMilliseconds
                || server.lastKnownUserCount != userCount
                || server.lastKnownMaximumUserCount != maximumUserCount else {
                continue
            }

            server.updateServerStatistics(
                pingMilliseconds: pingMilliseconds,
                userCount: userCount,
                maximumUserCount: maximumUserCount
            )
            shouldSave = true
        }

        guard shouldSave else {
            return
        }

        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save refreshed server status: \(error.localizedDescription)")
        }
    }
}

private struct ServerRefreshTarget: Hashable {
    let id: UUID
    let host: String
    let port: Int
}

private struct EmptySavedServersView: View {
    var body: some View {
        ContentUnavailableView(
            "No Saved Servers",
            systemImage: "server.rack",
            description: Text("Use Add New to create your first server entry.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Servername")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Ping")
                .frame(width: 70, alignment: .trailing)

            Text("Users")
                .frame(width: 90, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ServerRow: View {
    let server: SavedServer

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: server.isFavorite ? "heart.fill" : "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(server.isFavorite ? .red : .teal)

                Text(server.displayName)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(server.pingDisplayText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 70, alignment: .trailing)

            Text(server.usersDisplayText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
