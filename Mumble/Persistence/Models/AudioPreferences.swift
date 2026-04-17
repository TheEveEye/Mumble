import Foundation
import SwiftData

@Model
final class AudioPreferences {
    @Attribute(.unique) var id: UUID
    var profileName: String
    var inputVolume: Double
    var outputVolume: Double
    var voiceActivationThreshold: Double
    var isMicrophoneMuted: Bool
    var isOutputMuted: Bool
    var isNoiseSuppressionEnabled: Bool
    var localPushToTalkKey: String
    var shoutPushToTalkKey: String

    init(
        id: UUID = UUID(),
        profileName: String = "Default",
        inputVolume: Double = 1.0,
        outputVolume: Double = 1.0,
        voiceActivationThreshold: Double = 0.35,
        isMicrophoneMuted: Bool = false,
        isOutputMuted: Bool = false,
        isNoiseSuppressionEnabled: Bool = true,
        localPushToTalkKey: String = "#",
        shoutPushToTalkKey: String = ""
    ) {
        self.id = id
        self.profileName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.inputVolume = Self.clamp(inputVolume, range: 0.0 ... 2.0)
        self.outputVolume = Self.clamp(outputVolume, range: 0.0 ... 2.0)
        self.voiceActivationThreshold = Self.clamp(voiceActivationThreshold, range: 0.0 ... 1.0)
        self.isMicrophoneMuted = isMicrophoneMuted
        self.isOutputMuted = isOutputMuted
        self.isNoiseSuppressionEnabled = isNoiseSuppressionEnabled
        self.localPushToTalkKey = Self.normalizeHotkey(localPushToTalkKey)
        self.shoutPushToTalkKey = Self.normalizeHotkey(shoutPushToTalkKey)
    }

    func normalize() {
        inputVolume = Self.clamp(inputVolume, range: 0.0 ... 2.0)
        outputVolume = Self.clamp(outputVolume, range: 0.0 ... 2.0)
        voiceActivationThreshold = Self.clamp(voiceActivationThreshold, range: 0.0 ... 1.0)
        localPushToTalkKey = Self.normalizeHotkey(localPushToTalkKey)
        shoutPushToTalkKey = Self.normalizeHotkey(shoutPushToTalkKey)
    }

    static func defaultProfile() -> AudioPreferences {
        AudioPreferences()
    }

    static func clamp(_ value: Double, range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func normalizeHotkey(_ value: String) -> String {
        MumbleHotkey.normalizedStorage(from: value)
    }
}
