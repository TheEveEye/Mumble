import Foundation
import CoreAudio
import Testing
@testable import Mumble

struct MumbleAudioCaptureControllerTests {
    @Test
    func transmitAccumulatorSplitsSamplesIntoPacketSizedFrames() {
        var accumulator = MumbleTransmitPCMAccumulator()
        let inputSamples = (0..<1_000).map(Float.init)

        let frames = accumulator.append(samples: inputSamples)

        #expect(frames.count == 1)
        #expect(frames.first?.count == MumbleTransmitPCMAccumulator.packetFrameSize)
        #expect(frames.first?.first == 0)
        #expect(frames.first?.last == 959)
        #expect(accumulator.pendingSamples.count == 40)
    }

    @Test
    func transmitAccumulatorPadsFinalFrameOnStop() {
        var accumulator = MumbleTransmitPCMAccumulator()
        _ = accumulator.append(samples: [0.25, 0.5, 0.75])

        let finalFrame = accumulator.finishFrame()

        #expect(finalFrame.count == MumbleTransmitPCMAccumulator.packetFrameSize)
        #expect(Array(finalFrame.prefix(3)) == [0.25, 0.5, 0.75])
        #expect(finalFrame.dropFirst(3).allSatisfy { $0 == 0 })
        #expect(accumulator.pendingSamples.isEmpty)
    }

    @Test
    func frameSequencerAdvancesInTenMillisecondSteps() {
        var sequencer = MumbleTransmitFrameSequencer()

        let firstFrameNumber = sequencer.reserveFrameNumber(forPCMFrameCount: 960)
        let secondFrameNumber = sequencer.reserveFrameNumber(forPCMFrameCount: 960)

        #expect(firstFrameNumber == 0)
        #expect(secondFrameNumber == 2)
        #expect(sequencer.nextFrameNumber == 4)
    }

    @Test
    func inputDeviceSelectionUsesSystemDefaultForEmptySelection() {
        let defaultDevice = makeInputDevice(
            audioDeviceID: 1,
            uid: "default",
            displayName: "MacBook Pro Microphone",
            isDefaultInput: true,
            transportType: .builtIn
        )
        let selectedDevice = makeInputDevice(
            audioDeviceID: 2,
            uid: "usb",
            displayName: "USB Microphone",
            transportType: .usb
        )

        let resolution = MumbleAudioInputDeviceSelection.resolve(
            selectedUID: " ",
            devices: [defaultDevice, selectedDevice],
            defaultDevice: defaultDevice
        )

        #expect(resolution.device?.uid == defaultDevice.uid)
        guard case .systemDefault = resolution.source else {
            Issue.record("Expected system default device selection")
            return
        }
        #expect(resolution.requestedUID == nil)
    }

    @Test
    func inputDeviceSelectionUsesExactUID() {
        let defaultDevice = makeInputDevice(
            audioDeviceID: 1,
            uid: "default",
            displayName: "MacBook Pro Microphone",
            isDefaultInput: true,
            transportType: .builtIn
        )
        let selectedDevice = makeInputDevice(
            audioDeviceID: 2,
            uid: "airpods",
            displayName: "AirPods Microphone",
            transportType: .bluetooth
        )

        let resolution = MumbleAudioInputDeviceSelection.resolve(
            selectedUID: "airpods",
            devices: [defaultDevice, selectedDevice],
            defaultDevice: defaultDevice
        )

        #expect(resolution.device?.uid == selectedDevice.uid)
        guard case .selected = resolution.source else {
            Issue.record("Expected exact selected device")
            return
        }
        #expect(resolution.requestedUID == "airpods")
    }

    @Test
    func inputDeviceSelectionFallsBackWhenUIDIsMissing() {
        let defaultDevice = makeInputDevice(
            audioDeviceID: 1,
            uid: "default",
            displayName: "MacBook Pro Microphone",
            isDefaultInput: true,
            transportType: .builtIn
        )

        let resolution = MumbleAudioInputDeviceSelection.resolve(
            selectedUID: "missing",
            devices: [defaultDevice],
            defaultDevice: defaultDevice
        )

        #expect(resolution.device?.uid == defaultDevice.uid)
        guard case .missingSelectionFallback = resolution.source else {
            Issue.record("Expected missing selection fallback")
            return
        }
        #expect(resolution.didFallbackFromMissingSelection)
        #expect(resolution.requestedUID == "missing")
    }

    @Test
    func bluetoothInputDevicesAreFlaggedForWarnings() {
        let bluetoothDevice = makeInputDevice(
            audioDeviceID: 2,
            uid: "airpods",
            displayName: "AirPods Microphone",
            transportType: .bluetooth
        )
        let builtInDevice = makeInputDevice(
            audioDeviceID: 1,
            uid: "default",
            displayName: "MacBook Pro Microphone",
            transportType: .builtIn
        )

        #expect(bluetoothDevice.usesBluetoothInput)
        #expect(!builtInDevice.usesBluetoothInput)
    }

    @Test
    func outputDeviceSelectionUsesSystemDefaultForEmptySelection() {
        let defaultDevice = makeOutputDevice(
            audioDeviceID: 3,
            uid: "default-output",
            displayName: "MacBook Pro Speakers",
            isDefaultOutput: true,
            transportType: .builtIn
        )
        let selectedDevice = makeOutputDevice(
            audioDeviceID: 4,
            uid: "usb-output",
            displayName: "USB Output",
            transportType: .usb
        )

        let resolution = MumbleAudioOutputDeviceSelection.resolve(
            selectedUID: "",
            devices: [defaultDevice, selectedDevice],
            defaultDevice: defaultDevice
        )

        #expect(resolution.device?.uid == defaultDevice.uid)
        guard case .systemDefault = resolution.source else {
            Issue.record("Expected system default output device selection")
            return
        }
        #expect(resolution.requestedUID == nil)
    }

    @Test
    func outputDeviceSelectionUsesExactUID() {
        let defaultDevice = makeOutputDevice(
            audioDeviceID: 3,
            uid: "default-output",
            displayName: "MacBook Pro Speakers",
            isDefaultOutput: true,
            transportType: .builtIn
        )
        let selectedDevice = makeOutputDevice(
            audioDeviceID: 4,
            uid: "airpods-output",
            displayName: "AirPods",
            transportType: .bluetooth
        )

        let resolution = MumbleAudioOutputDeviceSelection.resolve(
            selectedUID: "airpods-output",
            devices: [defaultDevice, selectedDevice],
            defaultDevice: defaultDevice
        )

        #expect(resolution.device?.uid == selectedDevice.uid)
        guard case .selected = resolution.source else {
            Issue.record("Expected exact selected output device")
            return
        }
        #expect(resolution.requestedUID == "airpods-output")
    }

    @Test
    func outputDeviceSelectionFallsBackWhenUIDIsMissing() {
        let defaultDevice = makeOutputDevice(
            audioDeviceID: 3,
            uid: "default-output",
            displayName: "MacBook Pro Speakers",
            isDefaultOutput: true,
            transportType: .builtIn
        )

        let resolution = MumbleAudioOutputDeviceSelection.resolve(
            selectedUID: "missing-output",
            devices: [defaultDevice],
            defaultDevice: defaultDevice
        )

        #expect(resolution.device?.uid == defaultDevice.uid)
        guard case .missingSelectionFallback = resolution.source else {
            Issue.record("Expected missing output selection fallback")
            return
        }
        #expect(resolution.didFallbackFromMissingSelection)
        #expect(resolution.requestedUID == "missing-output")
    }

    @Test
    func outputDevicesCanRepresentOutputOnlyHardware() {
        let outputOnlyDevice = makeOutputDevice(
            audioDeviceID: 5,
            uid: "speakers",
            displayName: "External Speakers",
            hasInput: false,
            transportType: .usb
        )

        #expect(outputOnlyDevice.hasOutput)
        #expect(!outputOnlyDevice.hasInput)
    }

    private func makeInputDevice(
        audioDeviceID: AudioDeviceID,
        uid: String,
        displayName: String,
        isDefaultInput: Bool = false,
        transportType: MumbleAudioDeviceTransportType
    ) -> MumbleAudioInputDevice {
        MumbleAudioInputDevice(
            audioDeviceID: audioDeviceID,
            uid: uid,
            displayName: displayName,
            hasInput: true,
            hasOutput: false,
            isDefaultInput: isDefaultInput,
            transportType: transportType
        )
    }

    private func makeOutputDevice(
        audioDeviceID: AudioDeviceID,
        uid: String,
        displayName: String,
        hasInput: Bool = false,
        isDefaultOutput: Bool = false,
        transportType: MumbleAudioDeviceTransportType
    ) -> MumbleAudioOutputDevice {
        MumbleAudioOutputDevice(
            audioDeviceID: audioDeviceID,
            uid: uid,
            displayName: displayName,
            hasInput: hasInput,
            hasOutput: true,
            isDefaultOutput: isDefaultOutput,
            transportType: transportType
        )
    }
}
