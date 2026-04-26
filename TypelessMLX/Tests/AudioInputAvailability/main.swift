import Foundation
import TypelessMLXAudioInputSupport

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func testNoDevicesAreUnavailable() {
    expect(
        !AudioInputDeviceAvailability.hasAvailableInputDevice(inputChannelCounts: []),
        "empty device list should be unavailable"
    )
}

func testOutputOnlyDevicesAreUnavailable() {
    expect(
        !AudioInputDeviceAvailability.hasAvailableInputDevice(inputChannelCounts: [0, 0]),
        "devices with zero input channels should be unavailable"
    )
}

func testAnyInputChannelIsAvailable() {
    expect(
        AudioInputDeviceAvailability.hasAvailableInputDevice(inputChannelCounts: [0, 1, 0]),
        "one input-capable device should be available"
    )
}

func testInputChannelsRequireActualChannelsNotJustBuffers() {
    expect(
        !AudioInputDeviceAvailability.hasInputChannels(bufferChannelCounts: [0]),
        "a zero-channel buffer should not count as an input device"
    )
    expect(
        AudioInputDeviceAvailability.hasInputChannels(bufferChannelCounts: [0, 2]),
        "total channel count should determine input availability"
    )
}

testNoDevicesAreUnavailable()
testOutputOnlyDevicesAreUnavailable()
testAnyInputChannelIsAvailable()
testInputChannelsRequireActualChannelsNotJustBuffers()
print("TypelessMLXAudioInputAvailabilityTests passed")
