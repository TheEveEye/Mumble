import AppKit
import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var audioPreferences: [AudioPreferences]

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
                    }
                }
                .formStyle(.grouped)
                .padding(20)
                .frame(width: 520)
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
}

private struct HotkeyRecorderField: View {
    let title: String
    @Binding var storage: String
    let placeholder: String

    @State private var isRecording = false
    @State private var localEventMonitor: Any?
    @State private var globalEventMonitor: Any?

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
            handleRecordedEvent(event, consumeEvent: true)
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { event in
            _ = handleRecordedEvent(event, consumeEvent: false)
        }
    }

    private func handleRecordedEvent(_ event: NSEvent, consumeEvent: Bool) -> NSEvent? {
        guard isRecording else {
            return event
        }

        if event.type == .keyDown, event.keyCode == 53 {
            stopRecording()
            return consumeEvent ? nil : event
        }

        guard let hotkey = MumbleHotkey.recordingHotkey(from: event) else {
            return event
        }

        storage = hotkey.storageString
        stopRecording()
        return consumeEvent ? nil : event
    }

    private func stopRecording() {
        isRecording = false

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}
