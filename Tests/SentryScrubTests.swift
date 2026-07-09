import Foundation
import Testing

@testable import dictate

/// Pure-function tests for SentryConfiguration.scrub - no Sentry SDK start, no network.
@Suite
struct SentryScrubTests {
    @Test
    func scrubRedactsHomePathAndUsername() {
        let home = NSHomeDirectory()
        let user = NSUserName()
        let message = "Failed to read prompt file at \(home)/.dictate/prompt.txt for user \(user)"

        let scrubbed = SentryConfiguration.scrub(message)

        #expect(!scrubbed.contains(home))
        #expect(!scrubbed.contains(user))
        #expect(scrubbed.contains("~"))
        #expect(scrubbed.contains("<user>"))
    }

    @Test
    func scrubRedactsDeviceUID() {
        let message = "Bluetooth input device AA:BB:CC:DD:EE:FF disconnected mid-recording"

        let scrubbed = SentryConfiguration.scrub(message)

        #expect(!scrubbed.contains("AA:BB:CC:DD:EE:FF"))
        #expect(scrubbed.contains("<device-uid>"))
    }

    @Test
    func scrubLeavesOrdinaryDiagnosticTextUntouched() {
        let message = "Captured 48000 samples (3.0s)"

        #expect(SentryConfiguration.scrub(message) == message)
    }
}
