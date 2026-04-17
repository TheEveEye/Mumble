import AppKit
import ApplicationServices
import SwiftUI
import SwiftData

struct RootNavigationShell: View {
    let dependencies: AppDependencies

    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [SavedServer]
    @Query private var audioPreferences: [AudioPreferences]

    @State private var isPresentingConnectDialog = true
    @State private var connectDialogSelectionID: UUID?
    @State private var connectedServerID: UUID?
    @State private var logEntries = [
        ConsoleEntry(message: "Welcome to Mumble.", rendering: .plain)
    ]
    @State private var channelConnectionHandle: MumbleChannelListConnectionHandle?
    @State private var channelSnapshot: [MumbleChannel] = []
    @State private var userSnapshot: [MumbleUser] = []
    @State private var talkStatesBySessionID: [UInt32: MumbleUserTalkState] = [:]
    @State private var currentSessionID: UInt32?
    @State private var enteredServerPasswords: [UUID: String] = [:]
    @State private var isLoadingChannels = false
    @State private var connectionAttemptID = UUID()
    @State private var connectionStatus = "Not connected"
    @State private var passwordPromptContext: ServerPasswordPromptContext?
    @State private var certificateTrustPrompt: MumbleCertificateTrustChallenge?
    @State private var localPushToTalkMonitor: Any?
    @State private var globalPushToTalkMonitor: Any?
    @State private var activePushToTalkMode: MumblePushToTalkMode?
    @State private var activePushToTalkHotkey: MumbleHotkey?
    @State private var localPushToTalkHotkey: MumbleHotkey?
    @State private var shoutPushToTalkHotkey: MumbleHotkey?
    @State private var hasPromptedForBackgroundInputAccess = false

    private var activeServer: SavedServer? {
        guard let connectedServerID else {
            return nil
        }

        return servers.first(where: { $0.id == connectedServerID })
    }

    private var currentSessionUser: MumbleUser? {
        guard let currentSessionID else {
            return nil
        }

        return userSnapshot.first(where: { $0.id == currentSessionID })
    }

    private var hotkeyConfiguration: String {
        let preferences = audioPreferences.first
        let localKey = AudioPreferences.normalizeHotkey(preferences?.localPushToTalkKey ?? "#")
        let shoutKey = AudioPreferences.normalizeHotkey(preferences?.shoutPushToTalkKey ?? "")
        return "\(localKey)\u{0}\(shoutKey)"
    }

    var body: some View {
        HSplitView {
            ConsolePane(entries: logEntries, statusText: connectionStatus)
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)

            ConnectionDetailPlaceholderView(
                server: activeServer,
                channels: channelSnapshot,
                users: userSnapshot,
                talkStatesBySessionID: talkStatesBySessionID,
                currentSessionID: currentSessionID,
                currentSessionChannelID: currentSessionUser?.channelID,
                isLoadingChannels: isLoadingChannels,
                onJoinChannel: joinChannel,
                onMoveUser: moveUser(sessionID:to:)
            )
        }
        .task {
            do {
                try dependencies.persistence.ensureRequiredData(in: modelContext)
                try configureAudioPlaybackPreferences()
                syncActiveServer()
                syncPushToTalkHotkeys()
            } catch {
                dependencies.logger.error("Failed to bootstrap persistent data: \(error.localizedDescription)")
            }
        }
        .onChange(of: hotkeyConfiguration) {
            syncPushToTalkHotkeys()
        }
        .onChange(of: servers.count) {
            syncActiveServer()
        }
        .sheet(isPresented: $isPresentingConnectDialog) {
            ConnectServerDialog(
                logger: dependencies.logger,
                serverStatus: dependencies.serverStatus,
                selectedServerID: $connectDialogSelectionID
            ) { server in
                startConnection(to: server)
            }
        }
        .sheet(item: $passwordPromptContext) { context in
            ServerPasswordPrompt(context: context) { password, shouldRemember in
                enteredServerPasswords[context.serverID] = password
                updateRememberedPassword(
                    password,
                    shouldRemember: shouldRemember,
                    for: context.serverID
                )

                if let server = servers.first(where: { $0.id == context.serverID }) {
                    startConnection(to: server, password: password)
                }
            }
        }
        .sheet(item: $certificateTrustPrompt) { challenge in
            ServerCertificateTrustPrompt(challenge: challenge) { accept, remember in
                channelConnectionHandle?.resolveCertificateTrust(
                    challengeID: challenge.id,
                    accept: accept,
                    remember: remember
                )
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle(activeServer?.displayName ?? "Mumble")
        .onDisappear {
            removePushToTalkMonitor()
            resetPushToTalk()
            channelConnectionHandle?.cancel()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isPresentingConnectDialog = true
                } label: {
                    Image(systemName: "globe")
                }

                Button {} label: {
                    Image(systemName: "person.3.fill")
                }
                .disabled(true)

                Button {} label: {
                    Image(systemName: "mic.fill")
                }
                .disabled(true)

                Button {} label: {
                    Image(systemName: "headphones")
                }
                .disabled(true)

                Button {} label: {
                    Image(systemName: "message")
                }
                .disabled(true)

                SettingsLink {
                    Image(systemName: "gearshape.fill")
                }

                Button {} label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .disabled(true)

                Button {} label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(true)
            }
        }
    }

    private func syncActiveServer() {
        guard !servers.isEmpty else {
            channelConnectionHandle?.cancel()
            channelConnectionHandle = nil
            connectedServerID = nil
            connectDialogSelectionID = nil
            channelSnapshot = []
            userSnapshot = []
            talkStatesBySessionID = [:]
            currentSessionID = nil
            isLoadingChannels = false
            connectionStatus = "Not connected"
            Task { await dependencies.audioPlayback.stop() }
            return
        }

        if let connectedServerID, servers.contains(where: { $0.id == connectedServerID }) {
            connectDialogSelectionID = connectDialogSelectionID.flatMap { selectionID in
                servers.contains(where: { $0.id == selectionID }) ? selectionID : nil
            }
            return
        }

        connectedServerID = nil
        channelSnapshot = []
        userSnapshot = []
        talkStatesBySessionID = [:]
        currentSessionID = nil
        isLoadingChannels = false
        connectionStatus = "Not connected"

        if let connectDialogSelectionID, servers.contains(where: { $0.id == connectDialogSelectionID }) {
            return
        }

        connectDialogSelectionID = SavedServerPresentation.sorted(servers).first?.id
    }

    private func appendLog(_ message: String) {
        appendLog(message, rendering: .plain)
    }

    private func appendLog(_ message: String, rendering: ConsoleEntry.Rendering) {
        logEntries.append(ConsoleEntry(message: message, rendering: rendering))
    }

    private func startConnection(to server: SavedServer, password: String? = nil) {
        let attemptID = UUID()
        let serverID = server.id
        let serverDisplayName = server.displayName
        let endpointDescription = server.endpointDescription
        let audioInputPreferences = currentAudioInputPreferences()

        passwordPromptContext = nil
        resetPushToTalk()
        connectionAttemptID = attemptID
        channelConnectionHandle?.cancel()
        channelSnapshot = []
        userSnapshot = []
        talkStatesBySessionID = [:]
        currentSessionID = nil
        isLoadingChannels = true
        connectedServerID = serverID
        connectDialogSelectionID = serverID
        connectionStatus = "Connecting to \(serverDisplayName)"
        appendLog("Starting connection to \(serverDisplayName) (\(endpointDescription)).")

        let target = MumbleConnectionTarget(
            serverID: serverID,
            label: serverDisplayName,
            host: server.host,
            port: server.port,
            username: server.username,
            password: resolvedPassword(for: server, override: password)
        )

        channelConnectionHandle = dependencies.channelList.connect(
            to: target,
            inputVolume: audioInputPreferences.inputVolume,
            isMicrophoneMuted: audioInputPreferences.isMicrophoneMuted
        ) { event in
            Task { @MainActor in
                guard connectionAttemptID == attemptID else {
                    return
                }

                handleConnectionEvent(
                    event,
                    serverID: serverID,
                    serverDisplayName: serverDisplayName
                )
            }
        }
    }

    private func handleConnectionEvent(
        _ event: MumbleChannelListEvent,
        serverID: UUID,
        serverDisplayName: String
    ) {
        switch event {
        case .log(let message):
            appendLog(message)
        case .certificateTrustRequired(let challenge):
            appendLog("Certificate trust confirmation required for \(challenge.endpointDescription).")
            certificateTrustPrompt = challenge
        case .reconnecting(let reason, let attempt, let maximumAttempts, let delay):
            resetPushToTalk()
            certificateTrustPrompt = nil
            passwordPromptContext = nil
            currentSessionID = nil
            userSnapshot = []
            talkStatesBySessionID = [:]
            isLoadingChannels = channelSnapshot.isEmpty
            connectionStatus = "Reconnecting to \(serverDisplayName)"
            appendLog(reason)
            appendLog(
                "Reconnecting to \(serverDisplayName) in \(formattedReconnectDelay(delay)) (attempt \(attempt) of \(maximumAttempts))."
            )
        case .synchronized(let welcomeText, let synchronizedSessionID):
            isLoadingChannels = false
            currentSessionID = synchronizedSessionID
            connectionStatus = "Connected to \(serverDisplayName)"

            if let welcomeText, !welcomeText.isEmpty {
                appendLog("Welcome message:")
                appendLog(welcomeText, rendering: .html)
            }
        case .channelsUpdated(let channels):
            guard connectedServerID == serverID else {
                return
            }

            channelSnapshot = channels
            isLoadingChannels = false
        case .usersUpdated(let users):
            guard connectedServerID == serverID else {
                return
            }

            userSnapshot = users
        case .talkStateChanged(let sessionID, let talkState):
            guard connectedServerID == serverID else {
                return
            }

            if talkState == .passive {
                talkStatesBySessionID.removeValue(forKey: sessionID)
            } else {
                talkStatesBySessionID[sessionID] = talkState
            }
        case .failed(let reason, let rejectType):
            resetPushToTalk()
            certificateTrustPrompt = nil
            appendLog("Connection failed: \(reason)")
            channelConnectionHandle = nil
            connectedServerID = nil
            channelSnapshot = []
            userSnapshot = []
            talkStatesBySessionID = [:]
            currentSessionID = nil
            isLoadingChannels = false
            connectionStatus = "Not connected"

            if rejectType == .wrongServerPassword || rejectType == .wrongUserPassword {
                enteredServerPasswords.removeValue(forKey: serverID)
                removeRememberedPassword(for: serverID)
                passwordPromptContext = ServerPasswordPromptContext(
                    id: UUID(),
                    serverID: serverID,
                    serverLabel: serverDisplayName,
                    failureReason: reason,
                    rememberByDefault: true
                )
            }
        case .disconnected(let reason):
            resetPushToTalk()
            certificateTrustPrompt = nil
            if let reason, !reason.isEmpty {
                appendLog(reason)
            }

            channelConnectionHandle = nil
            connectedServerID = nil
            channelSnapshot = []
            userSnapshot = []
            talkStatesBySessionID = [:]
            currentSessionID = nil
            isLoadingChannels = false
            connectionStatus = "Not connected"
        }
    }

    private func joinChannel(_ channel: MumbleChannel) {
        guard let currentSessionID else {
            return
        }

        moveUser(sessionID: currentSessionID, to: channel)
    }

    private func moveUser(sessionID: UInt32, to channel: MumbleChannel) {
        if let existingUser = userSnapshot.first(where: { $0.id == sessionID }), existingUser.channelID == channel.id {
            return
        }

        let action = sessionID == currentSessionID ? "Joining channel" : "Moving user to"
        appendLog("\(action) \(channel.name).")
        channelConnectionHandle?.joinChannel(sessionID: sessionID, channelID: channel.id)
    }

    private func resolvedPassword(for server: SavedServer, override: String?) -> String? {
        if let override, !override.isEmpty {
            return override
        }

        if let transientPassword = enteredServerPasswords[server.id], !transientPassword.isEmpty {
            return transientPassword
        }

        do {
            return try dependencies.serverPasswordStore.password(for: server.id)
        } catch {
            dependencies.logger.error(
                "Failed to load remembered password for \(server.displayName): \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func updateRememberedPassword(_ password: String, shouldRemember: Bool, for serverID: UUID) {
        do {
            if shouldRemember {
                try dependencies.serverPasswordStore.savePassword(password, for: serverID)
            } else {
                try dependencies.serverPasswordStore.removePassword(for: serverID)
            }
        } catch {
            dependencies.logger.error("Failed to update remembered password: \(error.localizedDescription)")
        }
    }

    private func removeRememberedPassword(for serverID: UUID) {
        do {
            try dependencies.serverPasswordStore.removePassword(for: serverID)
        } catch {
            dependencies.logger.error("Failed to remove remembered password: \(error.localizedDescription)")
        }
    }

    private func configureAudioPlaybackPreferences() throws {
        let descriptor = FetchDescriptor<AudioPreferences>()
        guard let audioPreferences = try modelContext.fetch(descriptor).first else {
            return
        }

        Task {
            await dependencies.audioPlayback.updatePreferences(
                outputVolume: audioPreferences.outputVolume,
                isOutputMuted: audioPreferences.isOutputMuted
            )
        }
    }

    private func currentAudioInputPreferences() -> (inputVolume: Double, isMicrophoneMuted: Bool) {
        do {
            let descriptor = FetchDescriptor<AudioPreferences>()
            guard let audioPreferences = try modelContext.fetch(descriptor).first else {
                return (1.0, false)
            }

            return (audioPreferences.inputVolume, audioPreferences.isMicrophoneMuted)
        } catch {
            dependencies.logger.error("Failed to load audio input preferences: \(error.localizedDescription)")
            return (1.0, false)
        }
    }

    private func installPushToTalkMonitor() {
        removePushToTalkMonitor()
        ensureBackgroundInputAccessIfNeeded()

        let eventMask: NSEvent.EventTypeMask = [
            .keyDown,
            .keyUp,
            .otherMouseDown,
            .otherMouseUp,
            .flagsChanged,
            .systemDefined,
        ]

        localPushToTalkMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { event in
            handlePushToTalkEvent(event, consumeEvents: true)
        }

        globalPushToTalkMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { event in
            _ = handlePushToTalkEvent(event, consumeEvents: false)
        }
    }

    private func removePushToTalkMonitor() {
        if let localPushToTalkMonitor {
            NSEvent.removeMonitor(localPushToTalkMonitor)
            self.localPushToTalkMonitor = nil
        }

        if let globalPushToTalkMonitor {
            NSEvent.removeMonitor(globalPushToTalkMonitor)
            self.globalPushToTalkMonitor = nil
        }
    }

    private func syncPushToTalkHotkeys() {
        let preferences = audioPreferences.first
        localPushToTalkHotkey = MumbleHotkey.parse(
            AudioPreferences.normalizeHotkey(preferences?.localPushToTalkKey ?? "#")
        )
        shoutPushToTalkHotkey = MumbleHotkey.parse(
            AudioPreferences.normalizeHotkey(preferences?.shoutPushToTalkKey ?? "")
        )

        if
            let activePushToTalkHotkey,
            activePushToTalkHotkey != localPushToTalkHotkey,
            activePushToTalkHotkey != shoutPushToTalkHotkey
        {
            resetPushToTalk()
        }

        installPushToTalkMonitor()
    }

    private func handlePushToTalkEvent(_ event: NSEvent, consumeEvents: Bool) -> NSEvent? {
        if event.type == .flagsChanged {
            guard
                let currentPushToTalkHotkey = activePushToTalkHotkey,
                currentPushToTalkHotkey.modifiersStillPressed(in: event.modifierFlags) == false
            else {
                return event
            }

            activePushToTalkHotkey = nil
            activePushToTalkMode = nil
            stopPushToTalk()
            return consumeEvents ? nil : event
        }

        if let (mode, hotkey) = pushToTalkBinding(for: event) {
            if event.type == .keyDown || event.type == .otherMouseDown {
                if event.type == .keyDown && event.isARepeat {
                    return consumeEvents ? nil : event
                }

                if activePushToTalkMode != mode || activePushToTalkHotkey != hotkey {
                    activePushToTalkMode = mode
                    activePushToTalkHotkey = hotkey
                    startPushToTalk(mode: mode)
                }
                return consumeEvents ? nil : event
            }
        }

        guard let currentPushToTalkHotkey = activePushToTalkHotkey, currentPushToTalkHotkey.matchesRelease(event: event) else {
            return event
        }

        activePushToTalkHotkey = nil
        activePushToTalkMode = nil

        switch event.type {
        case .keyUp, .otherMouseUp:
            stopPushToTalk()
            return consumeEvents ? nil : event
        default:
            return event
        }
    }

    private func ensureBackgroundInputAccessIfNeeded() {
        guard hasPromptedForBackgroundInputAccess == false else {
            return
        }

        hasPromptedForBackgroundInputAccess = true

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)

        if isTrusted == false {
            dependencies.logger.info(
                "Background push-to-talk needs Accessibility access. macOS should prompt for it in System Settings."
            )
            appendLog("Background push-to-talk requires Accessibility access. Allow Mumble in System Settings if keys do not register while the app is unfocused.")
        }
    }

    private func pushToTalkBinding(for event: NSEvent) -> (MumblePushToTalkMode, MumbleHotkey)? {
        if let shoutPushToTalkHotkey, shoutPushToTalkHotkey.matchesPress(event: event) {
            return (.linkedChannels, shoutPushToTalkHotkey)
        }

        if let localPushToTalkHotkey, localPushToTalkHotkey.matchesPress(event: event) {
            return (.localChannel, localPushToTalkHotkey)
        }

        return nil
    }


    private func startPushToTalk(mode: MumblePushToTalkMode) {
        guard connectedServerID != nil, currentSessionID != nil else {
            return
        }

        channelConnectionHandle?.startTransmitting(mode: mode)
    }

    private func stopPushToTalk() {
        channelConnectionHandle?.stopTransmitting()
    }

    private func resetPushToTalk() {
        activePushToTalkMode = nil
        activePushToTalkHotkey = nil
        stopPushToTalk()
    }

    private func formattedReconnectDelay(_ delay: TimeInterval) -> String {
        let roundedDelay = Int(delay.rounded())
        return roundedDelay == 1 ? "1 second" : "\(roundedDelay) seconds"
    }
}

private struct ConsoleEntry: Identifiable {
    enum Rendering {
        case plain
        case html
    }

    let id = UUID()
    let timestamp = Date()
    let message: String
    let rendering: Rendering
}

private struct ConsolePane: View {
    let entries: [ConsoleEntry]
    let statusText: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        ConsoleEntryView(entry: entry)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }

            Divider()

            HStack {
                Text(statusText)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ConsoleEntryView: View {
    let entry: ConsoleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("[\(entry.timestamp.formatted(date: .omitted, time: .standard))]")
                .font(.system(.body, design: .monospaced))

            switch entry.rendering {
            case .plain:
                Text(entry.message)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            case .html:
                ConsoleHTMLText(html: entry.message)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ConsoleHTMLText: View {
    let html: String

    var body: some View {
        if let attributedString {
            Text(attributedString)
        } else {
            Text(html)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var attributedString: AttributedString? {
        guard let data = htmlDocument.data(using: .utf8) else {
            return nil
        }

        guard let mutableAttributedString = try? NSMutableAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ) else {
            return nil
        }

        normalizeColors(in: mutableAttributedString)
        normalizeFonts(in: mutableAttributedString)
        return try? AttributedString(mutableAttributedString, including: \.appKit)
    }

    private var htmlDocument: String {
        """
        <html>
        <head>
        <style>
        body {
            font-family: -apple-system;
            font-size: 13px;
            color: \(NSColor.labelColor.hexRGB);
            margin: 0;
        }
        a {
            color: #ff5f56;
            text-decoration: none;
        }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    private func normalizeColors(in attributedString: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributedString.length)

        attributedString.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        attributedString.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else {
                return
            }

            attributedString.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
        }
    }

    private func normalizeFonts(in attributedString: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributedString.length)

        attributedString.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let existingFont = value as? NSFont
            let pointSize = existingFont?.pointSize ?? 13
            let traits = existingFont?.fontDescriptor.symbolicTraits ?? []
            let weight: NSFont.Weight = traits.contains(.bold) ? .semibold : .regular
            attributedString.addAttribute(.font, value: NSFont.systemFont(ofSize: pointSize, weight: weight), range: range)
        }
    }
}

private extension NSColor {
    var hexRGB: String {
        guard let rgbColor = usingColorSpace(.deviceRGB) else {
            return "#FFFFFF"
        }

        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
