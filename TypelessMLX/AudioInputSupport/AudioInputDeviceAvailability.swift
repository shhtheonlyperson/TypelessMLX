import Foundation

public enum AudioInputDeviceAvailability {
    public static func inputChannelCount(bufferChannelCounts: [UInt32]) -> Int {
        bufferChannelCounts.reduce(0) { $0 + Int($1) }
    }

    public static func hasInputChannels(bufferChannelCounts: [UInt32]) -> Bool {
        inputChannelCount(bufferChannelCounts: bufferChannelCounts) > 0
    }

    public static func hasAvailableInputDevice(inputChannelCounts: [Int]) -> Bool {
        inputChannelCounts.contains { $0 > 0 }
    }
}
