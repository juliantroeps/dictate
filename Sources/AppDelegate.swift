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
    private let audioDevicePolicy = AudioDevicePolicy()
    private lazy var engineCoordinator = EngineCoordinator(settings: settings, overlay: overlay)
    private lazy var dictationCoordinator = DictationCoordinator(
        audioCapture: audioCapture,
        overlay: overlay,
        engineCoordinator: engineCoordinator,
        settings: settings
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

        popover.contentViewController = NSHostingController(rootView: SettingsView())
        popover.behavior = .transient

        AccessibilityPermission.requestIfNeeded()
        MicrophonePermission.requestInBackground()

        engineCoordinator.prepare()
        observeModelChange()

        audioCapture.onDeviceChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.handleDeviceChanged()
            }
        }

        if let uid = settings.selectedInputDeviceUID,
            let deviceID = SystemAudioController.audioDeviceID(forUID: uid)
        {
            SystemAudioController.setDefaultInputDevice(deviceID)
        }
        observeDeviceSelection()
        handleDeviceChanged()

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

    private func observeDeviceSelection() {
        withObservationTracking {
            _ = settings.selectedInputDeviceUID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let uid = self.settings.selectedInputDeviceUID,
                    let deviceID = SystemAudioController.audioDeviceID(forUID: uid)
                {
                    SystemAudioController.setDefaultInputDevice(deviceID)
                } else {
                    self.handleDeviceChanged()
                }
                self.observeDeviceSelection()
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
            print("[dictate] Key listener restarted after wake")
        } else {
            print("[dictate] Key listener restart failed after wake")
        }
    }

    private func handleDeviceChanged() {
        guard let defaultID = SystemAudioController.defaultInputDeviceID else { return }

        let selectedUID = settings.selectedInputDeviceUID
        let resolvedSelectedID = selectedUID.flatMap { SystemAudioController.audioDeviceID(forUID: $0) }

        switch audioDevicePolicy.action(
            for: .init(
                selectedInputDeviceUID: selectedUID,
                resolvedSelectedInputID: resolvedSelectedID,
                defaultInputID: defaultID,
                builtInInputID: SystemAudioController.builtInInputDeviceID,
                defaultInputIsBluetooth: SystemAudioController.isDeviceBluetooth(defaultID)
            )
        ) {
        case .applyManualSelection(let resolvedID):
            SystemAudioController.setDefaultInputDevice(resolvedID)
            print("[dictate] Re-applied manual selection: \(selectedUID ?? "unknown")")
            return
        case .fallbackToBuiltIn(let builtInID):
            SystemAudioController.setDefaultInputDevice(builtInID)
            print("[dictate] Auto-fallback: set system default to built-in mic")
            return
        case .keepCurrent:
            break
        }

        guard case .idle = overlay.state.phase else { return }
        let activeName: String
        if let resolvedID = resolvedSelectedID {
            activeName = SystemAudioController.deviceName(for: resolvedID) ?? "Selected mic"
        } else {
            activeName = SystemAudioController.defaultInputDeviceName ?? "Unknown mic"
        }
        overlay.showInfo(activeName, duration: 2.0)
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
