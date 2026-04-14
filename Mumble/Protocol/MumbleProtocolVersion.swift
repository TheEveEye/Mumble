import Foundation

enum MumbleProtocolVersion {
    static let currentMajor = 1
    static let currentMinor = 5

    static var displayString: String {
        "\(currentMajor).\(currentMinor)"
    }
}
