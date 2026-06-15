import Foundation
import Sentry

/// Centralized Sentry setup and the only file that imports Sentry. Purpose: crash and
/// unexpected-error visibility - surface when the app crashes or hits a failure that should
/// not happen, with breadcrumb context for why.
///
/// Privacy: this is a microphone/transcript app. Transcribed text and audio buffers must
/// NEVER reach Sentry. Only AppLogger diagnostic messages (counts, states, error values -
/// never transcript content) are forwarded via `breadcrumb` / `captureError`, and
/// `beforeSend` / `beforeBreadcrumb` are backstops. Do not pass transcript or injected text
/// to any forwarding call here or to any `SentrySDK.capture*` / breadcrumb / tag API.
enum SentryConfiguration {
    private static let dsn =
        "https://80022f1d7174b39b6d25e4df964878e1@o4510618909474816.ingest.de.sentry.io/4511557206933584"

    /// Starts the Sentry SDK. Call as early as possible (before `app.run()`).
    static func start() {
        SentrySDK.start { options in
            options.dsn = dsn

            #if DEBUG
                options.debug = true
            #endif

            /// Privacy: never send user IP / email / richer PII for a dictation app.
            options.sendDefaultPii = false

            /// Crash + macOS uncaught-NSException reporting. AppKit does not crash on an
            /// uncaught NSException by default, so this is required to capture them.
            options.enableCrashHandler = true
            options.enableUncaughtNSExceptionReporting = true

            /// Report unresponsive main-thread hangs - a "should not happen" in a
            /// key-driven menu-bar app.
            options.enableAppHangTracking = true

            /// No performance transactions or profiling: this integration is for crash and
            /// error visibility, not performance measurement.
            options.tracesSampleRate = 0.0

            /// Minimize captured context. No network calls happen in this app.
            options.enableNetworkBreadcrumbs = false
            options.maxBreadcrumbs = 50

            /// Backstop: strip PII even though none is intentionally attached.
            options.beforeSend = { event in
                event.user?.ipAddress = nil
                event.user?.email = nil
                event.request = nil
                return event
            }

            /// Backstop: drop console/log breadcrumbs that could carry app text.
            options.beforeBreadcrumb = { crumb in
                if crumb.category == "console" {
                    return nil
                }
                return crumb
            }
        }

        emitVerifyEventIfRequested()
    }

    /// Records a non-error log line (info/warning) as a breadcrumb. Breadcrumbs travel only
    /// as context attached to a later captured event or crash, never on their own. Pass
    /// diagnostic text only - never transcript content.
    static func breadcrumb(category: String, message: String, warning: Bool = false) {
        let crumb = Breadcrumb(level: warning ? .warning : .info, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Reports an error log line as a Sentry event so unexpected non-crash failures are
    /// visible, with recent breadcrumbs attached automatically. Diagnostic text only.
    static func captureError(category: String, message: String) {
        let crumb = Breadcrumb(level: .error, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(.error)
            scope.setTag(value: category, key: "log.category")
        }
    }

    /// Debug-only smoke test. Emits a single non-crashing event when
    /// `DICTATE_SENTRY_VERIFY=1` is set in the environment. Never runs in release and never
    /// fires during normal launches, so CI and everyday runs stay event-free.
    private static func emitVerifyEventIfRequested() {
        #if DEBUG
            if ProcessInfo.processInfo.environment["DICTATE_SENTRY_VERIFY"] == "1" {
                SentrySDK.capture(message: "Sentry verify - dictate")
            }
        #endif
    }
}
