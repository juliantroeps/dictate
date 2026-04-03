import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let keyListener = KeyListener()
    private let audioCapture = AudioCaptureManager()
    private let overlay = OverlayController()
    private let settings = Settings.shared
    private let runtimeState = DictationRuntimeState()
    private lazy var audioDeviceCoordinator = AudioDeviceCoordinator(settings: settings, overlay: overlay)
    private lazy var engineCoordinator = EngineCoordinator(settings: settings, overlay: overlay, runtimeState: runtimeState)
    private lazy var dictationCoordinator = DictationCoordinator(
        audioCapture: audioCapture,
        overlay: overlay,
        engineCoordinator: engineCoordinator,
        settings: settings,
        runtimeState: runtimeState
    )
    private var permissionTimer: Timer?
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "dictate")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.contentViewController = NSHostingController(rootView: SettingsView(engineRuntimeState: runtimeState))
        popover.behavior = .transient

        AccessibilityPermission.requestIfNeeded()
        MicrophonePermission.requestInBackground()

        engineCoordinator.prepare()
        audioDeviceCoordinator.applyStartupSelectionIfNeeded()
        audioDeviceCoordinator.handleInputConfigurationChanged()
        audioDeviceCoordinator.observeSelectionChanges()
        observeModelChange()
        audioCapture.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dictationCoordinator.handleAudioCaptureEvent(event)
                self.audioDeviceCoordinator.handleAudioCaptureEvent(event)
            }
        }

        setupWakeObserver()

        keyListener.onKeyDown = { [weak self] in
            self?.dictationCoordinator.handleKeyDown()
        }
        keyListener.onKeyUp = { [weak self] in
            self?.dictationCoordinator.handleKeyUp()
        }

        if AccessibilityPermission.isGranted {
            _ = keyListener.start()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if AccessibilityPermission.isGranted {
                        self.permissionTimer?.invalidate()
                        self.permissionTimer = nil
                        _ = self.keyListener.start()
                    }
                }
            }
        }
    }

    private func observeModelChange() {
        withObservationTracking {
            _ = settings.whisperModel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.engineCoordinator.reload(using: self.settings.whisperModel)
                self.observeModelChange()
            }
        }
    }

    private func setupWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartKeyListener()
            }
        }
    }

    private func restartKeyListener() {
        keyListener.stop()
        if keyListener.start() {
            AppLogger.app.info("Key listener restarted after wake")
        } else {
            AppLogger.app.error("Key listener restart failed after wake")
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
