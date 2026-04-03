import OSLog

enum AppLogger {
    static let app = CategoryLogger(category: "app")
    static let audio = CategoryLogger(category: "audio")
    static let device = CategoryLogger(category: "device")
    static let input = CategoryLogger(category: "input")
    static let permissions = CategoryLogger(category: "permissions")
    static let settings = CategoryLogger(category: "settings")
    static let transcription = CategoryLogger(category: "transcription")
}

struct CategoryLogger {
    private let logger: Logger
    private let category: String

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: "com.juliantroeps.dictate", category: category)
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        mirror(message, level: "DEBUG")
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        mirror(message, level: "INFO")
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        mirror(message, level: "WARN")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        mirror(message, level: "ERROR")
    }

    private func mirror(_ message: String, level: String) {
        fputs("[dictate][\(category)][\(level)] \(message)\n", stderr)
    }
}
