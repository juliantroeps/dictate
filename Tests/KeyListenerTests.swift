import Testing
import CoreGraphics

@testable import dictate

struct KeyListenerTests {
    // Helper: create a flagsChanged event with .maskSecondaryFn set or cleared.
    private func makeFlagsEvent(fnPressed: Bool) -> CGEvent {
        let event = CGEvent(source: nil)!
        if fnPressed {
            event.flags = CGEventFlags(rawValue: event.flags.rawValue | CGEventFlags.maskSecondaryFn.rawValue)
        } else {
            event.flags = CGEventFlags(rawValue: event.flags.rawValue & ~CGEventFlags.maskSecondaryFn.rawValue)
        }
        return event
    }

    @Test
    func tapDisabledByTimeoutResetsFnDown() {
        let listener = KeyListener()
        var keyDownCount = 0
        var keyUpCount = 0
        listener.onKeyDown = { keyDownCount += 1 }
        listener.onKeyUp = { keyUpCount += 1 }

        // Simulate Fn press to set fnDown = true.
        listener.handleEvent(type: .flagsChanged, event: makeFlagsEvent(fnPressed: true))
        #expect(listener.fnDown == true)
        #expect(keyDownCount == 1)

        // Now deliver tapDisabledByTimeout - fnDown should reset, callbacks NOT fired.
        listener.handleEvent(type: .tapDisabledByTimeout, event: makeFlagsEvent(fnPressed: false))
        #expect(listener.fnDown == false)
        // onKeyUp must NOT fire for a tap-disable event.
        #expect(keyUpCount == 0)
    }

    @Test
    func tapDisabledByUserInputDoesNotFireKeyUpCallback() {
        let listener = KeyListener()
        var keyUpCount = 0
        listener.onKeyUp = { keyUpCount += 1 }

        // Simulate Fn held down.
        listener.handleEvent(type: .flagsChanged, event: makeFlagsEvent(fnPressed: true))
        #expect(listener.fnDown == true)

        // Tap disabled by user input - must NOT invoke onKeyUp.
        listener.handleEvent(type: .tapDisabledByUserInput, event: makeFlagsEvent(fnPressed: false))
        #expect(keyUpCount == 0)
        #expect(listener.fnDown == false)
    }

    @Test
    func normalFnDownUpCycleStillFires() {
        let listener = KeyListener()
        var keyDownCount = 0
        var keyUpCount = 0
        listener.onKeyDown = { keyDownCount += 1 }
        listener.onKeyUp = { keyUpCount += 1 }

        // Fn press.
        listener.handleEvent(type: .flagsChanged, event: makeFlagsEvent(fnPressed: true))
        #expect(keyDownCount == 1)
        #expect(keyUpCount == 0)

        // Fn release.
        listener.handleEvent(type: .flagsChanged, event: makeFlagsEvent(fnPressed: false))
        #expect(keyDownCount == 1)
        #expect(keyUpCount == 1)
        #expect(listener.fnDown == false)
    }
}
