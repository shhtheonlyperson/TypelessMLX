import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

final class Logger {
    static let shared = Logger()

    private let logFileURL: URL
    private let queue = DispatchQueue(label: "com.typelessmlx.logger", qos: .utility)
    private let dateFormatter: DateFormatter
    private var fileHandle: FileHandle?

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TypelessMLX")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        logFileURL = logsDir.appendingPathComponent("typelessmlx.log")

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        // Truncate if over 5MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64, size > 5_000_000 {
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        }

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        fileHandle = FileHandle(forWritingAtPath: logFileURL.path)
        fileHandle?.seekToEndOfFile()

        log(.info, "Logger", "=== TypelessMLX started ===")
    }

    func log(_ level: LogLevel, _ component: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let threadName = Thread.isMainThread ? "main" : "bg"
        let line = "[\(timestamp)] [\(level.rawValue)] [\(component)] [\(threadName)] \(message)\n"

        queue.async { [weak self] in
            guard let self = self, let data = line.data(using: .utf8) else { return }
            self.fileHandle?.write(data)
            if level == .error || level == .warn {
                self.fileHandle?.synchronizeFile()
            }
        }

        #if DEBUG
        print(line, terminator: "")
        #endif
    }

    deinit {
        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()
    }
}

func logDebug(_ component: String, _ message: String) {
    Logger.shared.log(.debug, component, message)
}

func logInfo(_ component: String, _ message: String) {
    Logger.shared.log(.info, component, message)
}

func logWarn(_ component: String, _ message: String) {
    Logger.shared.log(.warn, component, message)
}

func logError(_ component: String, _ message: String) {
    Logger.shared.log(.error, component, message)
}
