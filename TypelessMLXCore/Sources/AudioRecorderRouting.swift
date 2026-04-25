import CoreAudio
import Foundation

public struct AudioInputDeviceInfo: Equatable {
    public let name: String
    public let uid: String
    public let transport: UInt32?

    public init(name: String, uid: String, transport: UInt32?) {
        self.name = name
        self.uid = uid
        self.transport = transport
    }
}

public enum AudioRecordingBackend: Equatable {
    case avAudioEngine
    case avAudioRecorder
}

public enum AudioRecorderRouting {
    public static func backend(for device: AudioInputDeviceInfo?) -> AudioRecordingBackend {
        guard let device else { return .avAudioEngine }

        let lowercasedName = device.name.lowercased()
        let isBluetooth = device.transport == kAudioDeviceTransportTypeBluetooth ||
                          device.transport == kAudioDeviceTransportTypeBluetoothLE ||
                          lowercasedName.contains("airpods") ||
                          lowercasedName.contains("bluetooth")

        return isBluetooth ? .avAudioRecorder : .avAudioEngine
    }

    public static func restartSettleDelay(now: Date, lastStoppedAt: Date?, interval: TimeInterval) -> TimeInterval {
        guard let lastStoppedAt else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastStoppedAt))
    }
}
