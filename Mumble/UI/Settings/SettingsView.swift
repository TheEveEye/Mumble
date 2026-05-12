import AppKit
import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var audioPreferences: [AudioPreferences]
    @AppStorage("inputMonitoringRelaunchRequired") private var inputMonitoringRelaunchRequired = false
    @State private var isInputMonitoringGranted = MumbleGlobalInputMonitor.hasListenEventAccess()

    var body: some View {
        Group {
            if let preferences = audioPreferences.first {
                Form {
                    Section("Push-to-Talk") {
                        HotkeyRecorderField(
                            title: "Linked Channels (Shout)",
                            storage: Binding(
                                get: { preferences.shoutPushToTalkKey },
                                set: { preferences.shoutPushToTalkKey = AudioPreferences.normalizeHotkey($0) }
                            ),
                            placeholder: "Disabled"
                        )

                        HotkeyRecorderField(
                            title: "Current Channel Only",
                            storage: Binding(
                                get: { preferences.localPushToTalkKey },
                                set: { preferences.localPushToTalkKey = AudioPreferences.normalizeHotkey($0) }
                            ),
                            placeholder: "Record channel hotkey"
                        )

                        Text("Supports modifier keybinds, function keys, and Mouse4/Mouse5. Leave the linked-channel hotkey blank to disable shouting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        InputMonitoringStatusRow(
                            isGranted: isInputMonitoringGranted,
                            relaunchRequired: inputMonitoringRelaunchRequired,
                            onRequestAccess: requestInputMonitoringAccess
                        )
                    }
                }
                .formStyle(.grouped)
                .padding(20)
                .frame(width: 520)
                .onAppear {
                    refreshInputMonitoringStatus()
                }
            } else {
                ProgressView()
                    .frame(width: 520, height: 180)
                    .task {
                        await ensureAudioPreferencesExist()
                    }
            }
        }
        .navigationTitle("Settings")
    }

    @MainActor
    private func ensureAudioPreferencesExist() async {
        guard audioPreferences.isEmpty else {
            return
        }

        let preferences = AudioPreferences.defaultProfile()
        modelContext.insert(preferences)
        try? modelContext.save()
    }

    private func refreshInputMonitoringStatus() {
        isInputMonitoringGranted = MumbleGlobalInputMonitor.hasListenEventAccess()
        if !isInputMonitoringGranted {
            inputMonitoringRelaunchRequired = false
        }
    }

    private func requestInputMonitoringAccess() {
        isInputMonitoringGranted = MumbleGlobalInputMonitor.requestListenEventAccess()
        if isInputMonitoringGranted {
            refreshInputMonitoringStatus()
        }
    }
}

private struct InputMonitoringStatusRow: View {
    let isGranted: Bool
    let relaunchRequired: Bool
    let onRequestAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Input Monitoring", systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
                Spacer()

                if !isGranted {
                    Button("Enable Input Monitoring", action: onRequestAccess)
                }
            }

            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusMessage: String {
        if isGranted && relaunchRequired {
            return "Input Monitoring is granted. Relaunch Mumble if global push-to-talk does not start in other apps."
        }

        if isGranted {
            return "Global push-to-talk is enabled for other apps."
        }

        return "Grant Input Monitoring to use push-to-talk while another app is focused. Focused-window push-to-talk still works without it."
    }
}

private struct HotkeyRecorderField: View {
    let title: String
    @Binding var storage: String
    let placeholder: String

    @State private var isRecording = false
    @State private var localEventMonitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()

            Button {
                toggleRecording()
            } label: {
                Text(buttonTitle)
                    .frame(minWidth: 220, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button("Clear") {
                storage = ""
                stopRecording()
            }
            .disabled(storage.isEmpty && !isRecording)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var buttonTitle: String {
        if isRecording {
            return "Press shortcut..."
        }

        return MumbleHotkey.parse(storage)?.displayName ?? placeholder
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true

        let eventMask: NSEvent.EventTypeMask = [.keyDown, .otherMouseDown, .systemDefined]

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { event in
            handleRecordedEvent(event)
        }
    }

    private func handleRecordedEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording else {
            return event
        }

        if event.type == .keyDown, event.keyCode == 53 {
            stopRecording()
            return nil
        }

        guard let hotkey = MumbleHotkey.recordingHotkey(from: event) else {
            return event
        }

        storage = hotkey.storageString
        stopRecording()
        return nil
    }

    private func stopRecording() {
        isRecording = false

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }
}
