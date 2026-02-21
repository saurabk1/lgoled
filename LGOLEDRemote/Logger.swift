import Foundation
import os.log

private let subsystem = "com.sk.LGOLEDRemote"

enum LogLevel: String {
    case debug   = "DEBUG"
    case info    = "INFO"
    case warning = "WARN"
    case error   = "ERROR"
}

protocol Logger {
    func log(_ level: LogLevel, _ message: String, file: String, line: Int)
}

extension Logger {
    func debug(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.debug, message, file: file, line: line)
    }
    func info(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.info, message, file: file, line: line)
    }
    func warning(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.warning, message, file: file, line: line)
    }
    func error(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.error, message, file: file, line: line)
    }
}

struct ConsoleLogger: Logger {
    private let discoveryLog = os.Logger(subsystem: subsystem, category: "Discovery")
    private let networkLog   = os.Logger(subsystem: subsystem, category: "Network")
    private let generalLog   = os.Logger(subsystem: subsystem, category: "General")

    func log(_ level: LogLevel, _ message: String, file: String, line: Int) {
        let dest: os.Logger = file.contains("Discovery") ? discoveryLog
                            : file.contains("Client")    ? networkLog
                            : generalLog
        let msg = "\(file):\(line) \(message)"
        switch level {
        case .debug:   dest.debug("\(msg, privacy: .public)")
        case .info:    dest.info("\(msg, privacy: .public)")
        case .warning: dest.warning("\(msg, privacy: .public)")
        case .error:   dest.error("\(msg, privacy: .public)")
        }
    }
}
