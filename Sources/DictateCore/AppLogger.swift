import OSLog

/// Sink for info/warning/error log lines; the app plugs in crash reporting here so
/// DictateCore itself never links Sentry. Diagnostic text only - never transcript content.
public protocol LogReporter: Sendable {
    func breadcrumb(category: String, message: String, warning: Bool)
    func captureError(category: String, message: String)
}

public enum AppLogger {
    public static let app = CategoryLogger(category: "app")
    public static let audio = CategoryLogger(category: "audio")
    public static let device = CategoryLogger(category: "device")
    public static let input = CategoryLogger(category: "input")
    public static let permissions = CategoryLogger(category: "permissions")
    public static let settings = CategoryLogger(category: "settings")
    public static let transcription = CategoryLogger(category: "transcription")

    private static let reporter = OSAllocatedUnfairLock<(any LogReporter)?>(initialState: nil)

    public static func setReporter(_ newReporter: (any LogReporter)?) {
        reporter.withLock { $0 = newReporter }
    }

    fileprivate static func currentReporter() -> (any LogReporter)? {
        reporter.withLock { $0 }
    }
}

public struct CategoryLogger: Sendable {
    private let logger: Logger
    private let category: String

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: "com.juliantroeps.dictate", category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        mirror(message, level: "DEBUG")
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        mirror(message, level: "INFO")
        AppLogger.currentReporter()?.breadcrumb(category: category, message: message, warning: false)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        mirror(message, level: "WARN")
        AppLogger.currentReporter()?.breadcrumb(category: category, message: message, warning: true)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        mirror(message, level: "ERROR")
        AppLogger.currentReporter()?.captureError(category: category, message: message)
    }

    private func mirror(_ message: String, level: String) {
        fputs("[dictate][\(category)][\(level)] \(message)\n", stderr)
    }
}
