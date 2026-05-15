import CoreAudio
import Foundation

enum MumbleAudioDeviceTransportType: String, Sendable {
    case builtIn
    case usb
    case bluetooth
    case virtual
    case aggregate
    case pci
    case fireWire
    case hdmi
    case displayPort
    case airPlay
    case thunderbolt
    case continuityCapture
    case other
    case unknown

    init(coreAudioValue: UInt32) {
        switch coreAudioValue {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeVirtual:
            self = .virtual
        case kAudioDeviceTransportTypeAggregate:
            self = .aggregate
        case kAudioDeviceTransportTypePCI:
            self = .pci
        case kAudioDeviceTransportTypeFireWire:
            self = .fireWire
        case kAudioDeviceTransportTypeHDMI:
            self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort:
            self = .displayPort
        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt:
            self = .thunderbolt
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            self = .continuityCapture
        case kAudioDeviceTransportTypeUnknown:
            self = .unknown
        default:
            self = .other
        }
    }

    var displayName: String {
        switch self {
        case .builtIn:
            return "Built-in"
        case .usb:
            return "USB"
        case .bluetooth:
            return "Bluetooth"
        case .virtual:
            return "Virtual"
        case .aggregate:
            return "Aggregate"
        case .pci:
            return "PCI"
        case .fireWire:
            return "FireWire"
        case .hdmi:
            return "HDMI"
        case .displayPort:
            return "DisplayPort"
        case .airPlay:
            return "AirPlay"
        case .thunderbolt:
            return "Thunderbolt"
        case .continuityCapture:
            return "Continuity Camera"
        case .other:
            return "Other"
        case .unknown:
            return "Unknown"
        }
    }
}

struct MumbleAudioInputDevice: Identifiable, Sendable {
    let audioDeviceID: AudioDeviceID
    let uid: String
    let displayName: String
    let hasInput: Bool
    let hasOutput: Bool
    let isDefaultInput: Bool
    let transportType: MumbleAudioDeviceTransportType

    var id: String {
        uid
    }

    var usesBluetoothInput: Bool {
        transportType == .bluetooth
    }

    var pickerDisplayName: String {
        var components = [displayName]
        if isDefaultInput {
            components.append("Default")
        }
        components.append(transportType.displayName)
        return components.joined(separator: " - ")
    }
}

struct MumbleAudioInputDeviceResolution: Sendable {
    enum Source: Sendable {
        case systemDefault
        case selected
        case missingSelectionFallback
    }

    let device: MumbleAudioInputDevice?
    let source: Source
    let requestedUID: String?

    var didFallbackFromMissingSelection: Bool {
        if case .missingSelectionFallback = source {
            return true
        }

        return false
    }
}

protocol MumbleAudioInputDeviceCatalog: Sendable {
    func inputDevices() throws -> [MumbleAudioInputDevice]
    func defaultInputDevice() throws -> MumbleAudioInputDevice?
}

extension MumbleAudioInputDeviceCatalog {
    func resolveInputDevice(selectedUID: String?) throws -> MumbleAudioInputDeviceResolution {
        let normalizedUID = MumbleAudioInputDeviceSelection.normalizedUID(selectedUID)
        let devices = try inputDevices()
        let defaultDevice = try defaultInputDevice()

        return MumbleAudioInputDeviceSelection.resolve(
            selectedUID: normalizedUID,
            devices: devices,
            defaultDevice: defaultDevice
        )
    }
}

enum MumbleAudioInputDeviceSelection {
    static func normalizedUID(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    static func resolve(
        selectedUID: String?,
        devices: [MumbleAudioInputDevice],
        defaultDevice: MumbleAudioInputDevice?
    ) -> MumbleAudioInputDeviceResolution {
        let normalizedUID = normalizedUID(selectedUID)

        guard let normalizedUID else {
            return MumbleAudioInputDeviceResolution(
                device: defaultDevice,
                source: .systemDefault,
                requestedUID: nil
            )
        }

        if let selectedDevice = devices.first(where: { $0.uid == normalizedUID }) {
            return MumbleAudioInputDeviceResolution(
                device: selectedDevice,
                source: .selected,
                requestedUID: normalizedUID
            )
        }

        return MumbleAudioInputDeviceResolution(
            device: defaultDevice,
            source: .missingSelectionFallback,
            requestedUID: normalizedUID
        )
    }
}

struct CoreAudioInputDeviceCatalog: MumbleAudioInputDeviceCatalog {
    func inputDevices() throws -> [MumbleAudioInputDevice] {
        let defaultDeviceID = try defaultInputDeviceID()

        return try allAudioDeviceIDs()
            .compactMap { deviceID -> MumbleAudioInputDevice? in
                let hasInput = try deviceHasChannels(deviceID, scope: kAudioDevicePropertyScopeInput)
                guard hasInput else {
                    return nil
                }

                let uid = try stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
                guard !uid.isEmpty else {
                    return nil
                }

                let displayName = try stringProperty(kAudioObjectPropertyName, deviceID: deviceID)
                let hasOutput = try deviceHasChannels(deviceID, scope: kAudioDevicePropertyScopeOutput)
                let transportTypeValue = try uint32Property(kAudioDevicePropertyTransportType, deviceID: deviceID)

                return MumbleAudioInputDevice(
                    audioDeviceID: deviceID,
                    uid: uid,
                    displayName: displayName.isEmpty ? uid : displayName,
                    hasInput: hasInput,
                    hasOutput: hasOutput,
                    isDefaultInput: deviceID == defaultDeviceID,
                    transportType: MumbleAudioDeviceTransportType(coreAudioValue: transportTypeValue)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefaultInput != rhs.isDefaultInput {
                    return lhs.isDefaultInput
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func defaultInputDevice() throws -> MumbleAudioInputDevice? {
        let defaultDeviceID = try defaultInputDeviceID()
        return try inputDevices().first { $0.audioDeviceID == defaultDeviceID }
    }

    private func allAudioDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw CoreAudioInputDeviceCatalogError.coreAudioStatus(status)
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else {
            throw CoreAudioInputDeviceCatalogError.coreAudioStatus(status)
        }

        return deviceIDs
    }

    private func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else {
            throw CoreAudioInputDeviceCatalogError.coreAudioStatus(status)
        }

        return deviceID
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return ""
        }

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr else {
            throw CoreAudioInputDeviceCatalogError.coreAudioStatus(status)
        }

        return value?.takeRetainedValue() as String? ?? ""
    }

    private func uint32Property(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return 0
        }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr else {
            throw CoreAudioInputDeviceCatalogError.coreAudioStatus(status)
        }

        return value
    }

    private func deviceHasChannels(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw CoreAudioInputDeviceCatalogError.coreAudioStatus(status)
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawPointer.deallocate()
        }

        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            rawPointer
        )
        guard status == noErr else {
            throw CoreAudioInputDeviceCatalogError.coreAudioStatus(status)
        }

        let audioBufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { channelCount, buffer in
            channelCount + Int(buffer.mNumberChannels)
        } > 0
    }
}

enum CoreAudioInputDeviceCatalogError: Error {
    case coreAudioStatus(OSStatus)
}
