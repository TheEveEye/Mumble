import AppKit
import SwiftUI
import SwiftData

private struct SelfMuteDeafState: Equatable {
    let isSelfMuted: Bool
    let isSelfDeafened: Bool

    var isEffectivelyMuted: Bool {
        isSelfMuted || isSelfDeafened
    }
}

struct RootNavigationShell: View {
    let dependencies: AppDependencies

    @Environment(\.modelContext) private var modelContext
    @Environment(\.appearsActive) private var appearsActive
    @Query private var servers: [SavedServer]
    @Query private var audioPreferences: [AudioPreferences]

    @State private var isPresentingConnectDialog = true
    @State private var connectDialogSelectionID: UUID?
    @State private var connectedServerID: UUID?
    @State private var logEntries = [
        ConsoleEntry(message: "Welcome to Mumble.", rendering: .plain)
    ]
    @State private var chatDraft = ""
    @State private var selectedChatTarget: MumbleChatTargetSelection?
    @State private var channelConnectionHandle: MumbleChannelListConnectionHandle?
    @State private var channelSnapshot: [MumbleChannel] = []
    @State private var userSnapshot: [MumbleUser] = []
    @State private var talkStatesBySessionID: [UInt32: MumbleUserTalkState] = [:]
    @State private var recentTalkers = TalkingUIRecentTalkerStore()
    @State private var talkingUICleanupTick = Date()
    @State private var currentSessionID: UInt32?
    @State private var enteredServerPasswords: [UUID: String] = [:]
    @State private var isLoadingChannels = false
    @State private var connectionAttemptID = UUID()
    @State private var passwordPromptContext: ServerPasswordPromptContext?
    @State private var certificateTrustPrompt: MumbleCertificateTrustChallenge?
    @State private var localPushToTalkMonitor: Any?
    @State private var globalPushToTalkMonitor: MumbleGlobalInputMonitor?
    @State private var pushToTalkInputController = MumblePushToTalkInputController()
    @State private var isLocalPushToTalkTransmitting = false
    @StateObject private var talkingUIPresenter = TalkingUIWindowPresenter()
    @AppStorage("isLogSidebarVisible") private var isCommunicationSidebarVisible = true
    @AppStorage("inputMonitoringRelaunchRequired") private var inputMonitoringRelaunchRequired = false
    @AppStorage(TalkingUISettingsStorage.isShownKey) private var isTalkingUIShown = TalkingUISettingsStorage.defaultIsShown
    @AppStorage(TalkingUISettingsStorage.retentionSecondsKey) private var talkingUIRetentionSeconds = TalkingUISettingsStorage.defaultRetentionSeconds
    @AppStorage(TalkingUISettingsStorage.fontSizePercentageKey) private var talkingUIFontSizePercentage = TalkingUISettingsStorage.defaultFontSizePercentage
    @AppStorage(TalkingUISettingsStorage.alwaysIncludeCurrentUserKey) private var talkingUIAlwaysIncludesCurrentUser = TalkingUISettingsStorage.defaultAlwaysIncludeCurrentUser
    @AppStorage(TalkingUISettingsStorage.automaticallyExpandsWidthKey) private var talkingUIAutomaticallyExpandsWidth = TalkingUISettingsStorage.defaultAutomaticallyExpandsWidth
    @State private var optimisticSelfMuteDeafState: SelfMuteDeafState?

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

    private var displayedUserSnapshot: [MumbleUser] {
        guard let currentSessionID else {
            return userSnapshot
        }

        let toolbarState = selfMuteDeafToolbarState
        return userSnapshot.map { user in
            guard user.id == currentSessionID else {
                return user
            }

            var displayedUser = user
            displayedUser.isSelfMuted = toolbarState.isSelfMuted
            displayedUser.isSelfDeafened = toolbarState.isSelfDeafened
            return displayedUser
        }
    }

    private var canUpdateSelfMuteDeafState: Bool {
        connectedServerID != nil && channelConnectionHandle != nil && currentSessionUser != nil
    }

    private var canSendChatMessage: Bool {
        resolvedChatTarget != nil
    }

    private var resolvedChatTarget: MumbleResolvedChatTarget? {
        guard channelConnectionHandle != nil else {
            return nil
        }

        return MumbleChatTargetResolver.resolve(
            selection: selectedChatTarget,
            currentSessionID: currentSessionID,
            currentChannelID: currentSessionUser?.channelID,
            channels: channelSnapshot,
            users: userSnapshot
        )
    }

    private var canCurrentSessionTransmitVoice: Bool {
        guard var currentSessionUser else {
            return false
        }

        if let optimisticSelfMuteDeafState {
            currentSessionUser.isSelfMuted = optimisticSelfMuteDeafState.isSelfMuted
            currentSessionUser.isSelfDeafened = optimisticSelfMuteDeafState.isSelfDeafened
        }

        return currentSessionUser.canTransmitVoice
    }

    private var currentSelfMuteDeafState: SelfMuteDeafState? {
        currentSessionUser.map {
            SelfMuteDeafState(
                isSelfMuted: $0.isSelfMuted,
                isSelfDeafened: $0.isSelfDeafened
            )
        }
    }

    private var selfMuteDeafToolbarState: SelfMuteDeafState {
        optimisticSelfMuteDeafState ?? currentSelfMuteDeafState ?? SelfMuteDeafState(
            isSelfMuted: false,
            isSelfDeafened: false
        )
    }

    private var isCurrentSessionEffectivelyMuted: Bool {
        selfMuteDeafToolbarState.isEffectivelyMuted
    }

    private var canToggleTalkingUI: Bool {
        activeServer != nil
    }

    private var talkingUIToolbarHelpText: String {
        talkingUIPresenter.isVisible ? "Close Talking UI" : "Open Talking UI"
    }

    private var talkingUIToolbarColor: Color {
        toolbarStatusColor(talkingUIPresenter.isVisible ? Color.accentColor : Color.primary)
    }

    private var communicationSidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            isCommunicationSidebarVisible ? .all : .detailOnly
        } set: { visibility in
            switch visibility {
            case .detailOnly:
                isCommunicationSidebarVisible = false
            default:
                isCommunicationSidebarVisible = true
            }
        }
    }

    private var normalizedTalkingUIRetentionSeconds: Int {
        min(max(talkingUIRetentionSeconds, 1), 30)
    }

    private var normalizedTalkingUIFontSizePercentage: Int {
        min(max(talkingUIFontSizePercentage, 75), 150)
    }

    private var talkingUIRetentionInterval: TimeInterval {
        TimeInterval(normalizedTalkingUIRetentionSeconds)
    }

    private var talkingUISnapshot: TalkingUISnapshot {
        let now = talkingUICleanupTick
        return TalkingUISnapshot(
            entries: recentTalkers.visibleEntries(
                users: displayedUserSnapshot,
                channels: channelSnapshot,
                currentSessionID: currentSessionID,
                alwaysIncludeCurrentUser: talkingUIAlwaysIncludesCurrentUser,
                now: now
            ),
            fontSizePercentage: normalizedTalkingUIFontSizePercentage,
            automaticallyExpandsWidth: talkingUIAutomaticallyExpandsWidth,
            columnCount: 1
        )
    }

    private var selfMuteToolbarImageName: String {
        isCurrentSessionEffectivelyMuted ? "mic.slash.fill" : "mic.fill"
    }

    private var selfMuteToolbarHelpText: String {
        isCurrentSessionEffectivelyMuted ? "Unmute yourself" : "Mute yourself"
    }

    private var selfMuteToolbarColor: Color {
        toolbarStatusColor(isCurrentSessionEffectivelyMuted ? Color.red : Color.green)
    }

    private var selfDeafenToolbarImageName: String {
        selfMuteDeafToolbarState.isSelfDeafened ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    private var selfDeafenToolbarHelpText: String {
        selfMuteDeafToolbarState.isSelfDeafened ? "Undeafen yourself" : "Deafen yourself"
    }

    private var selfDeafenToolbarColor: Color {
        toolbarStatusColor(selfMuteDeafToolbarState.isSelfDeafened ? Color.red : Color.green)
    }

    private func toolbarStatusColor(_ color: Color) -> Color {
        color.opacity(appearsActive ? 1.0 : 0.55)
    }

    private var hotkeyConfiguration: String {
        let preferences = audioPreferences.first
        let localKey = AudioPreferences.normalizeHotkey(preferences?.localPushToTalkKey ?? "#")
        let shoutKey = AudioPreferences.normalizeHotkey(preferences?.shoutPushToTalkKey ?? "")
        return "\(localKey)\u{0}\(shoutKey)"
    }

    private var playbackConfiguration: String {
        let preferences = audioPreferences.first
        let outputVolume = preferences?.outputVolume ?? 1.0
        let isOutputMuted = preferences?.isOutputMuted ?? false
        let selectedOutputDeviceUID = AudioPreferences.normalizeOutputDeviceUID(preferences?.selectedOutputDeviceUID) ?? ""
        return "\(outputVolume)\u{0}\(isOutputMuted)\u{0}\(selectedOutputDeviceUID)"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: communicationSidebarColumnVisibility) {
            CommunicationSidebar(
                logEntries: logEntries,
                chatDraft: $chatDraft,
                canSendMessage: canSendChatMessage,
                onSendChatMessage: sendChatMessage
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            ConnectionDetailPlaceholderView(
                server: activeServer,
                channels: channelSnapshot,
                users: displayedUserSnapshot,
                talkStatesBySessionID: talkStatesBySessionID,
                currentSessionID: currentSessionID,
                currentSessionChannelID: currentSessionUser?.channelID,
                isLoadingChannels: isLoadingChannels,
                selectedChatTarget: $selectedChatTarget,
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
                synchronizeTalkingUIWindow()
            } catch {
                dependencies.logger.error("Failed to bootstrap persistent data: \(error.localizedDescription)")
            }
        }
        .task {
            await runTalkingUICleanupLoop()
        }
        .onChange(of: hotkeyConfiguration) {
            syncPushToTalkHotkeys()
        }
        .onChange(of: isTalkingUIShown) {
            synchronizeTalkingUIWindow()
        }
        .onChange(of: talkingUIRetentionSeconds) {
            synchronizeTalkingUIWindow()
        }
        .onChange(of: talkingUIFontSizePercentage) {
            synchronizeTalkingUIWindow()
        }
        .onChange(of: talkingUIAlwaysIncludesCurrentUser) {
            synchronizeTalkingUIWindow()
        }
        .onChange(of: talkingUIAutomaticallyExpandsWidth) {
            synchronizeTalkingUIWindow()
        }
        .onChange(of: playbackConfiguration) {
            do {
                try configureAudioPlaybackPreferences()
            } catch {
                dependencies.logger.error("Failed to update audio playback preferences: \(error.localizedDescription)")
            }
        }
        .onChange(of: appearsActive) {
            if appearsActive {
                installPushToTalkMonitor()
            }
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
        .frame(minWidth: 640, minHeight: 320)
        .navigationTitle(activeServer?.displayName ?? "Mumble")
        .onAppear {
            talkingUIPresenter.visibilityDidChange = { isVisible in
                isTalkingUIShown = isVisible
            }
        }
        .onDisappear {
            removePushToTalkMonitor()
            resetPushToTalk()
            channelConnectionHandle?.cancel()
            talkingUIPresenter.close(notify: false)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isPresentingConnectDialog = true
                } label: {
                    Image(systemName: "globe")
                }

                Button {
                    toggleTalkingUI()
                } label: {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(talkingUIToolbarColor)
                }
                .disabled(!canToggleTalkingUI)
                .help(talkingUIToolbarHelpText)

                Button {
                    toggleSelfMute()
                } label: {
                    Image(systemName: selfMuteToolbarImageName)
                        .foregroundStyle(selfMuteToolbarColor)
                }
                .disabled(!canUpdateSelfMuteDeafState)
                .help(selfMuteToolbarHelpText)

                Button {
                    toggleSelfDeafen()
                } label: {
                    Image(systemName: selfDeafenToolbarImageName)
                        .foregroundStyle(selfDeafenToolbarColor)
                }
                .disabled(!canUpdateSelfMuteDeafState)
                .help(selfDeafenToolbarHelpText)

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
            isLocalPushToTalkTransmitting = false
            recentTalkers.clear()
            currentSessionID = nil
            optimisticSelfMuteDeafState = nil
            selectedChatTarget = nil
            isLoadingChannels = false
            synchronizeTalkingUIWindow()
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
        isLocalPushToTalkTransmitting = false
        recentTalkers.clear()
        currentSessionID = nil
        optimisticSelfMuteDeafState = nil
        selectedChatTarget = nil
        isLoadingChannels = false
        synchronizeTalkingUIWindow()

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

    private func sendChatMessage(_ message: String) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedMessage.isEmpty,
            let channelConnectionHandle,
            let target = resolvedChatTarget
        else {
            return
        }

        let escapedMessage = MumbleChatMessageFormatter.htmlEscapedPlainText(trimmedMessage)

        switch target {
        case .channel(let channel):
            channelConnectionHandle.sendChannelTextMessage(channelID: channel.id, message: escapedMessage)
        case .user(let user):
            channelConnectionHandle.sendUserTextMessage(sessionID: user.id, message: escapedMessage)
        }

        appendLog(
            "To \(MumbleChatMessageFormatter.escapedHTML(target.displayName)): \(escapedMessage)",
            rendering: .html
        )
    }

    private func appendTextMessage(_ message: MumbleTextMessage) {
        let actorName = message.actorSessionID
            .flatMap { sessionID in userSnapshot.first(where: { $0.id == sessionID })?.name }
            ?? "Server"
        let escapedActorName = MumbleChatMessageFormatter.escapedHTML(actorName)
        let prefix: String
        if let scope = message.scope {
            prefix = "(\(scope.displayName)) \(escapedActorName)"
        } else {
            prefix = escapedActorName
        }

        appendLog("\(prefix): \(message.message)", rendering: .html)
    }

    private func reconcileSelectedChatTarget() {
        guard let selectedChatTarget else {
            return
        }

        switch selectedChatTarget {
        case .channel(let channelID):
            if channelSnapshot.contains(where: { $0.id == channelID }) == false {
                self.selectedChatTarget = nil
            }
        case .user(let sessionID):
            if userSnapshot.contains(where: { $0.id == sessionID }) == false {
                self.selectedChatTarget = nil
            }
        }
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
        isLocalPushToTalkTransmitting = false
        recentTalkers.clear()
        currentSessionID = nil
        optimisticSelfMuteDeafState = nil
        selectedChatTarget = nil
        isLoadingChannels = true
        connectedServerID = serverID
        connectDialogSelectionID = serverID
        synchronizeTalkingUIWindow()
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
            isMicrophoneMuted: audioInputPreferences.isMicrophoneMuted,
            selectedInputDeviceUID: audioInputPreferences.selectedInputDeviceUID
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
            isLocalPushToTalkTransmitting = false
            recentTalkers.clear()
            optimisticSelfMuteDeafState = nil
            selectedChatTarget = nil
            isLoadingChannels = channelSnapshot.isEmpty
            synchronizeTalkingUIWindow()
            appendLog(reason)
            appendLog(
                "Reconnecting to \(serverDisplayName) in \(formattedReconnectDelay(delay)) (attempt \(attempt) of \(maximumAttempts))."
            )
        case .synchronized(let welcomeText, let synchronizedSessionID):
            isLoadingChannels = false
            currentSessionID = synchronizedSessionID
            synchronizeTalkingUIWindow()

            if let welcomeText, !welcomeText.isEmpty {
                appendLog("Welcome message:")
                appendLog(welcomeText, rendering: .html)
            }
        case .channelsUpdated(let channels):
            guard connectedServerID == serverID else {
                return
            }

            channelSnapshot = channels
            reconcileSelectedChatTarget()
            isLoadingChannels = false
            synchronizeTalkingUIWindow()
        case .usersUpdated(let users):
            guard connectedServerID == serverID else {
                return
            }

            userSnapshot = users
            reconcileSelectedChatTarget()
            recentTalkers.reconcileKnownUsers(users)
            reconcileOptimisticSelfMuteDeafState()
            clearCurrentSessionTalkingStateIfSpeechIsBlocked()
            synchronizeTalkingUIWindow()
        case .talkStateChanged(let sessionID, let talkState):
            guard connectedServerID == serverID else {
                return
            }

            let now = Date()
            if sessionID == currentSessionID, talkState != .passive, canCurrentSessionTransmitVoice == false {
                clearCurrentSessionTalkingState(now: now, stopTransmitting: true)
                return
            }

            if talkState == .passive {
                talkStatesBySessionID.removeValue(forKey: sessionID)
                if sessionID == currentSessionID {
                    isLocalPushToTalkTransmitting = false
                }
            } else {
                talkStatesBySessionID[sessionID] = talkState
            }
            recentTalkers.apply(
                sessionID: sessionID,
                talkState: talkState,
                now: now,
                retentionSeconds: talkingUIRetentionInterval
            )
            synchronizeTalkingUIWindow(now: now)
        case .textMessage(let message):
            appendTextMessage(message)
        case .failed(let reason, let rejectType):
            resetPushToTalk()
            certificateTrustPrompt = nil
            appendLog("Connection failed: \(reason)")
            channelConnectionHandle = nil
            connectedServerID = nil
            channelSnapshot = []
            userSnapshot = []
            talkStatesBySessionID = [:]
            isLocalPushToTalkTransmitting = false
            recentTalkers.clear()
            currentSessionID = nil
            optimisticSelfMuteDeafState = nil
            selectedChatTarget = nil
            isLoadingChannels = false
            synchronizeTalkingUIWindow()

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
            isLocalPushToTalkTransmitting = false
            recentTalkers.clear()
            currentSessionID = nil
            optimisticSelfMuteDeafState = nil
            selectedChatTarget = nil
            isLoadingChannels = false
            synchronizeTalkingUIWindow()
        }
    }

    private func toggleTalkingUI() {
        guard canToggleTalkingUI else {
            return
        }

        isTalkingUIShown.toggle()
        synchronizeTalkingUIWindow()
    }

    private func synchronizeTalkingUIWindow(now: Date = Date()) {
        talkingUICleanupTick = now
        recentTalkers.cleanupExpired(now: now)
        recentTalkers.reconcileKnownUsers(userSnapshot)

        guard isTalkingUIShown, canToggleTalkingUI else {
            talkingUIPresenter.close(notify: false)
            return
        }

        talkingUIPresenter.show(snapshot: talkingUISnapshot)
    }

    private func runTalkingUICleanupLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }

            await MainActor.run {
                synchronizeTalkingUIWindow()
            }
        }
    }

    private func reconcileOptimisticSelfMuteDeafState() {
        guard let optimisticSelfMuteDeafState else {
            return
        }

        guard let currentSelfMuteDeafState else {
            self.optimisticSelfMuteDeafState = nil
            return
        }

        if currentSelfMuteDeafState == optimisticSelfMuteDeafState {
            self.optimisticSelfMuteDeafState = nil
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

    private func toggleSelfMute() {
        guard canUpdateSelfMuteDeafState else {
            return
        }

        let currentToolbarState = selfMuteDeafToolbarState
        let isEffectivelyMuted = currentToolbarState.isEffectivelyMuted
        let nextIsSelfMuted = !isEffectivelyMuted
        let nextIsSelfDeafened = isEffectivelyMuted ? false : currentToolbarState.isSelfDeafened
        optimisticSelfMuteDeafState = SelfMuteDeafState(
            isSelfMuted: nextIsSelfMuted,
            isSelfDeafened: nextIsSelfDeafened
        )
        clearCurrentSessionTalkingStateIfSpeechIsBlocked()
        synchronizeTalkingUIWindow()
        channelConnectionHandle?.setSelfMuteDeafState(
            isSelfMuted: nextIsSelfMuted,
            isSelfDeafened: nextIsSelfDeafened
        )
    }

    private func toggleSelfDeafen() {
        guard canUpdateSelfMuteDeafState else {
            return
        }

        let currentToolbarState = selfMuteDeafToolbarState
        let nextIsSelfDeafened = !currentToolbarState.isSelfDeafened
        let nextIsSelfMuted = nextIsSelfDeafened ? true : currentToolbarState.isSelfMuted
        optimisticSelfMuteDeafState = SelfMuteDeafState(
            isSelfMuted: nextIsSelfMuted,
            isSelfDeafened: nextIsSelfDeafened
        )
        clearCurrentSessionTalkingStateIfSpeechIsBlocked()
        synchronizeTalkingUIWindow()
        channelConnectionHandle?.setSelfMuteDeafState(
            isSelfMuted: nextIsSelfMuted,
            isSelfDeafened: nextIsSelfDeafened
        )
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
                isOutputMuted: audioPreferences.isOutputMuted,
                selectedOutputDeviceUID: AudioPreferences.normalizeOutputDeviceUID(audioPreferences.selectedOutputDeviceUID)
            )
        }
    }

    private func currentAudioInputPreferences() -> (inputVolume: Double, isMicrophoneMuted: Bool, selectedInputDeviceUID: String?) {
        do {
            let descriptor = FetchDescriptor<AudioPreferences>()
            guard let audioPreferences = try modelContext.fetch(descriptor).first else {
                return (1.0, false, nil)
            }

            return (
                audioPreferences.inputVolume,
                audioPreferences.isMicrophoneMuted,
                AudioPreferences.normalizeInputDeviceUID(audioPreferences.selectedInputDeviceUID)
            )
        } catch {
            dependencies.logger.error("Failed to load audio input preferences: \(error.localizedDescription)")
            return (1.0, false, nil)
        }
    }

    private func installPushToTalkMonitor() {
        removePushToTalkMonitor()

        if MumbleGlobalInputMonitor.hasListenEventAccess() {
            let monitor = MumbleGlobalInputMonitor { event in
                handlePushToTalkEvent(event)
            }

            do {
                try monitor.start()
                globalPushToTalkMonitor = monitor
                inputMonitoringRelaunchRequired = false
                return
            } catch MumbleGlobalInputMonitor.StartError.eventTapUnavailable {
                inputMonitoringRelaunchRequired = true
                dependencies.logger.error("Input Monitoring is granted, but the global push-to-talk event tap could not start. Relaunch Mumble and try again.")
            } catch {
                dependencies.logger.error("Failed to start global push-to-talk monitoring: \(error.localizedDescription)")
            }
        }

        let eventMask: NSEvent.EventTypeMask = [
            .keyDown,
            .keyUp,
            .otherMouseDown,
            .otherMouseUp,
            .flagsChanged,
            .systemDefined,
        ]

        localPushToTalkMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { event in
            handlePushToTalkEvent(event)
        }
    }

    private func removePushToTalkMonitor() {
        if let localPushToTalkMonitor {
            NSEvent.removeMonitor(localPushToTalkMonitor)
            self.localPushToTalkMonitor = nil
        }

        globalPushToTalkMonitor?.stop()
        globalPushToTalkMonitor = nil
    }

    private func syncPushToTalkHotkeys() {
        let preferences = audioPreferences.first
        let result = pushToTalkInputController.updateHotkeys(
            local: MumbleHotkey.parse(
                AudioPreferences.normalizeHotkey(preferences?.localPushToTalkKey ?? "#")
            ),
            linkedChannels: MumbleHotkey.parse(
                AudioPreferences.normalizeHotkey(preferences?.shoutPushToTalkKey ?? "")
            )
        )

        applyPushToTalkResult(result)

        installPushToTalkMonitor()
    }

    private func handlePushToTalkEvent(_ event: NSEvent) -> NSEvent? {
        guard let inputEvent = MumbleInputEvent(event: event) else {
            return event
        }

        let result = pushToTalkInputController.handle(inputEvent)
        applyPushToTalkResult(result)
        return result.shouldConsumeLocalEvent ? nil : event
    }

    private func handlePushToTalkEvent(_ event: MumbleInputEvent) {
        applyPushToTalkResult(pushToTalkInputController.handle(event))
    }

    private func applyPushToTalkResult(_ result: MumblePushToTalkInputResult) {
        switch result.action {
        case .none:
            return
        case .start(let mode):
            startPushToTalk(mode: mode)
        case .stop:
            stopPushToTalk()
        }
    }


    private func startPushToTalk(mode: MumblePushToTalkMode) {
        guard connectedServerID != nil, let currentSessionID else {
            return
        }

        guard canCurrentSessionTransmitVoice else {
            clearCurrentSessionTalkingState(stopTransmitting: true)
            return
        }

        let audioInputPreferences = currentAudioInputPreferences()
        channelConnectionHandle?.updateAudioInputPreferences(
            inputVolume: audioInputPreferences.inputVolume,
            isMicrophoneMuted: audioInputPreferences.isMicrophoneMuted,
            selectedInputDeviceUID: audioInputPreferences.selectedInputDeviceUID
        )
        isLocalPushToTalkTransmitting = true
        talkStatesBySessionID[currentSessionID] = mode.talkState
        let now = Date()
        recentTalkers.apply(
            sessionID: currentSessionID,
            talkState: mode.talkState,
            now: now,
            retentionSeconds: talkingUIRetentionInterval
        )
        synchronizeTalkingUIWindow(now: now)
        channelConnectionHandle?.startTransmitting(mode: mode)
    }

    private func stopPushToTalk() {
        let didTransmit = isLocalPushToTalkTransmitting
        isLocalPushToTalkTransmitting = false

        if let currentSessionID {
            let now = Date()
            talkStatesBySessionID.removeValue(forKey: currentSessionID)
            if didTransmit {
                recentTalkers.apply(
                    sessionID: currentSessionID,
                    talkState: .passive,
                    now: now,
                    retentionSeconds: talkingUIRetentionInterval
                )
            }
            synchronizeTalkingUIWindow(now: now)
        }

        channelConnectionHandle?.stopTransmitting()
    }

    private func clearCurrentSessionTalkingStateIfSpeechIsBlocked() {
        guard canCurrentSessionTransmitVoice == false else {
            return
        }

        clearCurrentSessionTalkingState(stopTransmitting: true)
    }

    private func clearCurrentSessionTalkingState(now: Date = Date(), stopTransmitting: Bool) {
        guard let currentSessionID else {
            isLocalPushToTalkTransmitting = false
            return
        }

        let hadTalkingState = isLocalPushToTalkTransmitting || talkStatesBySessionID[currentSessionID] != nil
        isLocalPushToTalkTransmitting = false
        talkStatesBySessionID.removeValue(forKey: currentSessionID)
        recentTalkers.remove(sessionID: currentSessionID)

        if hadTalkingState {
            synchronizeTalkingUIWindow(now: now)
        }

        if stopTransmitting, hadTalkingState {
            channelConnectionHandle?.stopTransmitting()
        }
    }

    private func resetPushToTalk() {
        applyPushToTalkResult(pushToTalkInputController.reset())
    }

    private func formattedReconnectDelay(_ delay: TimeInterval) -> String {
        let roundedDelay = Int(delay.rounded())
        return roundedDelay == 1 ? "1 second" : "\(roundedDelay) seconds"
    }
}

enum MumbleResolvedChatTarget: Equatable {
    case channel(MumbleChannel)
    case user(MumbleUser)

    var displayName: String {
        switch self {
        case .channel(let channel):
            return channel.name
        case .user(let user):
            return user.name
        }
    }
}

enum MumbleChatTargetResolver {
    static func resolve(
        selection: MumbleChatTargetSelection?,
        currentSessionID: UInt32?,
        currentChannelID: UInt32?,
        channels: [MumbleChannel],
        users: [MumbleUser]
    ) -> MumbleResolvedChatTarget? {
        guard let currentSessionID else {
            return nil
        }

        if let selection {
            switch selection {
            case .channel(let channelID):
                if let channel = channels.first(where: { $0.id == channelID }) {
                    return .channel(channel)
                }
            case .user(let sessionID):
                if sessionID != currentSessionID, let user = users.first(where: { $0.id == sessionID }) {
                    return .user(user)
                }
            }
        }

        guard
            let currentChannelID,
            let currentChannel = channels.first(where: { $0.id == currentChannelID })
        else {
            return nil
        }

        return .channel(currentChannel)
    }
}

enum MumbleChatMessageFormatter {
    static func htmlEscapedPlainText(_ text: String) -> String {
        escapedHTML(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
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

private struct CommunicationSidebar: View {
    let logEntries: [ConsoleEntry]
    @Binding var chatDraft: String
    let canSendMessage: Bool
    let onSendChatMessage: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConsolePane(entries: logEntries)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ChatInputBar(
                draft: $chatDraft,
                canSendMessage: canSendMessage,
                onSend: onSendChatMessage
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatInputBar: View {
    @Binding var draft: String
    let canSendMessage: Bool
    let onSend: (String) -> Void
    @State private var isSendButtonHovered = false

    private var canSend: Bool {
        canSendMessage && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draft)
                .textFieldStyle(.plain)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(.thinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.28), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                )

            Button(action: send) {
                ZStack {
                    Circle()
                        .fill(
                            canSend
                                ? Color.accentColor.opacity(isSendButtonHovered ? 0.95 : 0.82)
                                : Color.secondary.opacity(0.16)
                        )
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(canSend ? 0.34 : 0.18), lineWidth: 1)
                        )
                        .shadow(
                            color: canSend ? Color.accentColor.opacity(0.22) : .clear,
                            radius: 8,
                            y: 2
                        )

                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canSend ? .white : .secondary)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send Message")
            .onHover { isSendButtonHovered = $0 }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }

    private func send() {
        let message = draft
        guard canSend else {
            return
        }

        onSend(message)
        draft = ""
    }
}

private struct ConsolePane: View {
    let entries: [ConsoleEntry]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    ConsoleEntryView(entry: entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
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
