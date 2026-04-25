import CoreAudio
import Foundation
import TypelessMLXCore

enum TestFailure: Error, CustomStringConvertible {
    case expectationFailed(String)

    var description: String {
        switch self {
        case .expectationFailed(let message): return message
        }
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure.expectationFailed("\(message): expected \(expected), got \(actual)")
    }
}

func expectEqual(_ actual: TimeInterval, _ expected: TimeInterval, accuracy: TimeInterval, _ message: String) throws {
    guard abs(actual - expected) <= accuracy else {
        throw TestFailure.expectationFailed("\(message): expected \(expected), got \(actual)")
    }
}

let tests: [(String, () throws -> Void)] = [
    ("AirPods input uses AVAudioRecorder fallback", {
        let device = AudioInputDeviceInfo(
            name: "ShihChi's AirPods Pro",
            uid: "airpods-input",
            transport: nil
        )
        try expectEqual(
            AudioRecorderRouting.backend(for: device),
            .avAudioRecorder,
            "AirPods should bypass AVAudioEngine installTap"
        )
    }),
    ("Bluetooth transport uses AVAudioRecorder fallback", {
        let device = AudioInputDeviceInfo(
            name: "Headset Microphone",
            uid: "bluetooth-input",
            transport: kAudioDeviceTransportTypeBluetooth
        )
        try expectEqual(
            AudioRecorderRouting.backend(for: device),
            .avAudioRecorder,
            "Bluetooth transport should bypass AVAudioEngine installTap"
        )
    }),
    ("Bluetooth LE transport uses AVAudioRecorder fallback", {
        let device = AudioInputDeviceInfo(
            name: "Wireless Microphone",
            uid: "bluetooth-le-input",
            transport: kAudioDeviceTransportTypeBluetoothLE
        )
        try expectEqual(
            AudioRecorderRouting.backend(for: device),
            .avAudioRecorder,
            "Bluetooth LE transport should bypass AVAudioEngine installTap"
        )
    }),
    ("Built-in input uses AVAudioEngine tap path", {
        let device = AudioInputDeviceInfo(
            name: "MacBook Pro Microphone",
            uid: "built-in-input",
            transport: 0
        )
        try expectEqual(
            AudioRecorderRouting.backend(for: device),
            .avAudioEngine,
            "Built-in microphones should keep the live AVAudioEngine tap path"
        )
    }),
    ("Unknown input uses AVAudioEngine tap path", {
        try expectEqual(
            AudioRecorderRouting.backend(for: nil),
            .avAudioEngine,
            "Unknown devices should keep existing AVAudioEngine behavior"
        )
    }),
    ("Quick restarts get a settle delay", {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let lastStoppedAt = now.addingTimeInterval(-0.25)
        try expectEqual(
            AudioRecorderRouting.restartSettleDelay(now: now, lastStoppedAt: lastStoppedAt, interval: 1.25),
            1.0,
            accuracy: 0.001,
            "Restarting immediately after stop should wait for CoreAudio to settle"
        )
    }),
    ("Settled restarts do not wait", {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let lastStoppedAt = now.addingTimeInterval(-2.0)
        try expectEqual(
            AudioRecorderRouting.restartSettleDelay(now: now, lastStoppedAt: lastStoppedAt, interval: 1.25),
            0,
            accuracy: 0.001,
            "Restarting after the settle interval should not wait"
        )
    })
]

do {
    for (name, test) in tests {
        try test()
        print("PASS \(name)")
    }
    print("All \(tests.count) regression tests passed")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
