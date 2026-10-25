import DictateCore
import Foundation

/// Saves the exact samples handed to `transcribe()` (plus context) so real dictations can
/// become an eval corpus for `dictate-eval`. Opt-in via `DICTATE_SAVE_CAPTURES=1`; files
/// stay on this machine in `~/.dictate/captures/` and are never uploaded or logged.
struct CaptureRecorder: Sendable {
    static let environmentKey = "DICTATE_SAVE_CAPTURES"
    static let sampleRate = 16_000

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dictate/captures")

    struct InputDevice: Sendable, Equatable {
        var name: String?
        var isBluetooth: Bool?
    }

    /// `<stamp>.json` next to `<stamp>.wav`. Keys are snake_case on disk.
    struct Sidecar: Codable, Equatable {
        var timestamp: Date
        var audioSeconds: Double
        var sampleCount: Int
        var sampleRate: Int
        var model: String
        var inputDevice: String?
        var bluetooth: Bool?
        /// What the app transcribed; nil when transcription failed (see `error`).
        var hypothesis: String?
        var error: String?
    }

    let directory: URL
    let now: @Sendable () -> Date

    init(directory: URL = Self.defaultDirectory, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    /// nil unless the env flag is exactly "1". Read once at startup.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CaptureRecorder? {
        environment[environmentKey] == "1" ? CaptureRecorder() : nil
    }

    /// Default input device as the capture path used it (AudioDeviceCoordinator sets it as system default).
    static func systemInputDevice() -> InputDevice {
        guard let id = SystemAudioController.defaultInputDeviceID else { return InputDevice() }
        return InputDevice(
            name: SystemAudioController.deviceName(for: id),
            isBluetooth: SystemAudioController.isDeviceBluetooth(id))
    }

    /// Fire-and-forget: file IO runs off the caller's actor so key-up -> text latency is untouched.
    func save(samples: [Float], model: String, device: InputDevice, hypothesis: String?, error: String?) {
        let sidecar = Sidecar(
            timestamp: now(),
            audioSeconds: Double(samples.count) / Double(Self.sampleRate),
            sampleCount: samples.count,
            sampleRate: Self.sampleRate,
            model: model,
            inputDevice: device.name,
            bluetooth: device.isBluetooth,
            hypothesis: hypothesis,
            error: error)
        Task.detached(priority: .utility) {
            do {
                let url = try write(samples: samples, sidecar: sidecar)
                // Path only: info/warning lines become crash-report breadcrumbs, so no transcript text here.
                AppLogger.audio.debug("Saved capture \(url.lastPathComponent)")
            } catch {
                AppLogger.audio.warning("Saving capture failed: \(error)")
            }
        }
    }

    /// Writes `<stamp>.wav` + `<stamp>.json`; returns the wav URL.
    @discardableResult
    func write(samples: [Float], sidecar: Sidecar) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let stamp = Self.fileStamp(sidecar.timestamp)
        let wavURL = directory.appendingPathComponent("\(stamp).wav")
        let jsonURL = directory.appendingPathComponent("\(stamp).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        try Self.wavData(samples: samples, sampleRate: sidecar.sampleRate).write(to: wavURL, options: .atomic)
        try encoder.encode(sidecar).write(to: jsonURL, options: .atomic)
        for url in [wavURL, jsonURL] {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return wavURL
    }

    /// Local time with milliseconds, e.g. `20261025-101112-123`; sorts chronologically.
    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    /// Mono 32-bit float WAV so the file holds the exact `[Float]` (16-bit would quantize it).
    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 4
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 56 + dataSize)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(48 + dataSize))  // "WAVE" (4) + fmt chunk (24) + fact chunk (12) + data header (8) + data
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(3))  // WAVE_FORMAT_IEEE_FLOAT
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerSample))
        append(UInt16(bytesPerSample))
        append(UInt16(32))
        data.append(contentsOf: Array("fact".utf8))  // required for non-PCM formats
        append(UInt32(4))
        append(UInt32(samples.count))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        for sample in samples {
            append(sample.bitPattern)
        }
        return data
    }
}
