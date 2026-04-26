import AVFoundation
import Foundation

public final class AudioTapFileWriter {
    private let url: URL
    private var file: AVAudioFile?

    public init(url: URL) {
        self.url = url
    }

    public var hasOpenedFile: Bool {
        file != nil
    }

    @discardableResult
    public func write(_ buffer: AVAudioPCMBuffer) throws -> Bool {
        let openedFile = file == nil
        if file == nil {
            file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        }
        guard let file else { return false }
        try file.write(from: buffer)
        return openedFile
    }
}
