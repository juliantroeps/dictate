import AppKit
import SwiftUI

@main
struct Application {
    static func main() {
        SentryConfiguration.start()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate

        app.run()
    }
}
