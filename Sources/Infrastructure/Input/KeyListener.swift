import CoreGraphics
import Foundation

final class KeyListener {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDown = false

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    func start() -> Bool {
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<KeyListener>.fromOpaque(userInfo).takeUnretainedValue()
                listener.handleFlagsChanged(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            AppLogger.app.error("Failed to create event tap. Accessibility permission may not be granted.")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        AppLogger.app.info("Key listener started")
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        fnDown = false
        AppLogger.app.info("Key listener stopped")
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let fnPressed = event.flags.contains(.maskSecondaryFn)

        if fnPressed && !fnDown {
            fnDown = true
            onKeyDown?()
        } else if !fnPressed && fnDown {
            fnDown = false
            onKeyUp?()
        }
    }
}
