import AVFoundation
import Foundation
import TypelessMLXAudioTapSupport

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16) else {
        throw NSError(domain: "TypelessMLXAudioTapFormatTests", code: 1)
    }
    buffer.frameLength = 16
    return buffer
}

func temporaryAudioURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("typelessmlx-test-\(UUID().uuidString).wav")
}

func testWriteOpensFileWithFirstBufferFormat() throws {
    let url = temporaryAudioURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let buffer = try makeBuffer(sampleRate: 44_100, channels: 2)
    let writer = AudioTapFileWriter(url: url)

    expect(!writer.hasOpenedFile, "writer should start unopened")
    let openedFile = try writer.write(buffer)
    expect(openedFile, "first write should open the file")
    expect(writer.hasOpenedFile, "writer should be open after first write")

    let file = try AVAudioFile(forReading: url)
    expect(abs(file.processingFormat.sampleRate - 44_100) < 0.1, "file should use first buffer sample rate")
    expect(file.processingFormat.channelCount == 2, "file should use first buffer channel count")
}

func testSubsequentWriteReusesExistingFile() throws {
    let url = temporaryAudioURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let buffer = try makeBuffer(sampleRate: 48_000, channels: 1)
    let writer = AudioTapFileWriter(url: url)

    let firstWriteOpenedFile = try writer.write(buffer)
    let secondWriteOpenedFile = try writer.write(buffer)
    expect(firstWriteOpenedFile, "first write should open the file")
    expect(!secondWriteOpenedFile, "second write should reuse the existing file")
}

try testWriteOpensFileWithFirstBufferFormat()
try testSubsequentWriteReusesExistingFile()
print("TypelessMLXAudioTapFormatTests passed")
