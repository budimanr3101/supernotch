import AppKit
import Carbon.HIToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

struct LiveTranslateShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = LiveTranslateShortcut(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: UInt32(controlKey | optionKey),
        keyLabel: "L"
    )

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }

        let safeGlobalModifiers = UInt32(cmdKey | optionKey | controlKey)
        guard modifiers & safeGlobalModifiers != 0 else { return nil }

        let characters = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let label = (characters?.isEmpty == false ? characters : nil)
            ?? "Key \(event.keyCode)"

        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyLabel: label
        )
    }

    var displayString: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    var conflictsWithFileShelf: Bool {
        modifiers == UInt32(cmdKey)
            && (keyCode == UInt32(kVK_ANSI_X) || keyCode == UInt32(kVK_ANSI_V))
    }
}

@MainActor
final class SuperNotchLiveTranslateFeature: NSObject {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case failed(String)
    }

    private static let keyCodeKey = "SuperNotch.LiveTranslate.keyCode"
    private static let modifiersKey = "SuperNotch.LiveTranslate.modifiers"
    private static let labelKey = "SuperNotch.LiveTranslate.keyLabel"
    private let signature: OSType = 0x4E534C54 // NSLT

    var onCaption: ((String, String, Bool) -> Void)?
    var onStateChanged: ((State) -> Void)?
    var onShortcutChanged: (() -> Void)?

    private let registry = SuperNotchFeatureRegistry.shared
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioQueue = DispatchQueue(
        label: "com.budiman.supernotch.live-translate.audio",
        qos: .userInitiated
    )

    private var stream: SCStream?
    private var streamOutput: LiveTranslateStreamOutput?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var shortcut: LiveTranslateShortcut
    private var hotKey: EventHotKeyRef?
    private var shortcutInstalled = false
    private var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.keyCodeKey) != nil,
           defaults.object(forKey: Self.modifiersKey) != nil {
            shortcut = LiveTranslateShortcut(
                keyCode: UInt32(defaults.integer(forKey: Self.keyCodeKey)),
                modifiers: UInt32(defaults.integer(forKey: Self.modifiersKey)),
                keyLabel: defaults.string(forKey: Self.labelKey) ?? "?"
            )
        } else {
            shortcut = .defaultShortcut
        }
        super.init()
    }

    var isRunning: Bool {
        switch state {
        case .starting, .listening:
            return true
        case .idle, .failed:
            return false
        }
    }

    var isEnabled: Bool {
        registry.isEnabled(.liveTranslate)
    }

    var shortcutDescription: String {
        shortcut.displayString
    }

    func installShortcut() {
        guard !shortcutInstalled else { return }

        let handlerStatus = CarbonHotKeyCenter.shared.setHandler(
            signature: signature,
            id: 1
        ) { [weak self] in
            guard let self else { return OSStatus(eventNotHandledErr) }
            guard self.isEnabled else {
                NSSound.beep()
                return noErr
            }

            self.toggle()
            return noErr
        }

        guard handlerStatus == noErr else {
            NSLog("[SuperNotch] Live Translate hotkey handler failed: %d", handlerStatus)
            return
        }

        shortcutInstalled = true
        let registerStatus = registerShortcut()
        if registerStatus != noErr {
            CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
            shortcutInstalled = false
        }

        NSLog(registerStatus == noErr
            ? "[SuperNotch] Live Translate shortcut ready on \(shortcut.displayString)"
            : "[SuperNotch] Live Translate shortcut unavailable: \(shortcut.displayString)")
    }

    func uninstallShortcut() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        hotKey = nil
        CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
        shortcutInstalled = false
    }

    func setFeatureEnabled(_ enabled: Bool) {
        registry.setEnabled(.liveTranslate, enabled: enabled)
        if !enabled {
            stop()
        }
    }

    func showShortcutRecorder() {
        let alert = NSAlert()
        alert.messageText = "Live Translate Shortcut"
        alert.informativeText = "Press a global shortcut using ⌘, ⌥, or ⌃. Shift may be added."

        let recorder = LiveTranslateShortcutCaptureView(current: shortcut)
        alert.accessoryView = recorder
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn,
              let captured = recorder.captured else { return }

        guard setShortcut(captured) else {
            let error = NSAlert()
            error.messageText = "Shortcut Unavailable"
            error.informativeText = "\(captured.displayString) is already used or reserved."
            error.alertStyle = .warning
            error.runModal()
            return
        }

        onShortcutChanged?()
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        guard registry.isEnabled(.liveTranslate) else {
            state = .failed("Live Translate is disabled in Settings → Features.")
            return
        }

        state = .starting
        onCaption?("", "Starting Live Translate…", true)

        Task {
            do {
                try await authorizeSpeech()
                try await startRecognition()
                try await startSystemAudioCapture()
                state = .listening
                onCaption?("", "Listening to meeting audio…", true)
            } catch {
                stopInternals()
                let message = userFacingMessage(for: error)
                state = .failed(message)
                onCaption?("", message, false)
            }
        }
    }

    func stop() {
        stopInternals()
        state = .idle
    }

    private func setShortcut(_ newValue: LiveTranslateShortcut) -> Bool {
        guard !newValue.conflictsWithFileShelf else { return false }

        let previous = shortcut
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }

        shortcut = newValue

        if shortcutInstalled, registerShortcut() != noErr {
            shortcut = previous
            _ = registerShortcut()
            return false
        }

        let defaults = UserDefaults.standard
        defaults.set(Int(newValue.keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(newValue.modifiers), forKey: Self.modifiersKey)
        defaults.set(newValue.keyLabel, forKey: Self.labelKey)
        return true
    }

    private func registerShortcut() -> OSStatus {
        guard shortcutInstalled else { return OSStatus(eventNotHandledErr) }

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(0),
            &reference
        )

        if status == noErr {
            hotKey = reference
        }
        return status
    }

    private func authorizeSpeech() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard status == .authorized else {
            throw LiveTranslateError.speechPermission
        }

        guard speechRecognizer?.isAvailable == true else {
            throw LiveTranslateError.speechUnavailable
        }
    }

    private func startRecognition() async throws {
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        recognitionRequest = request

        guard let speechRecognizer else {
            throw LiveTranslateError.speechUnavailable
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else { return }

                Task { @MainActor in
                    self.handleRecognizedText(text, isFinal: result.isFinal)
                }
            }

            if let error {
                Task { @MainActor in
                    guard self.isRunning else { return }
                    NSLog("[SuperNotch] Live Translate speech error: %@", error.localizedDescription)
                }
            }
        }
    }

    private func startSystemAudioCapture() async throws {
        // Do not gate ScreenCaptureKit behind CGPreflightScreenCaptureAccess().
        // On some macOS builds, especially with replaced/unsigned app bundles,
        // the CoreGraphics preflight can report false even though Screen &
        // System Audio Recording is enabled in System Settings. ScreenCaptureKit
        // is the authority here, so attempt capture directly and surface its
        // real error if macOS rejects the session.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard let display = preferredDisplay(in: content) else {
            throw LiveTranslateError.noDisplay
        }

        let currentBundleID = Bundle.main.bundleIdentifier
        let excludedApplications = content.applications.filter {
            $0.bundleIdentifier == currentBundleID
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.queueDepth = 2
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let output = LiveTranslateStreamOutput { [weak self] sampleBuffer in
            self?.recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)

        self.streamOutput = output
        self.stream = stream
        try await stream.startCapture()
        NSLog("[SuperNotch] Live Translate system-audio capture started")
    }

    private func preferredDisplay(in content: SCShareableContent) -> SCDisplay? {
        guard let notchScreen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let screenNumber = notchScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return content.displays.first
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        return content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
    }

    private func handleRecognizedText(_ text: String, isFinal: Bool) {
        onCaption?(text, "", !isFinal)
    }

    private func stopInternals() {
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let stream {
            Task {
                try? await stream.stopCapture()
            }
        }

        stream = nil
        streamOutput = nil
        NSLog("[SuperNotch] Live Translate stopped")
    }

    private func userFacingMessage(for error: Error) -> String {
        if let liveError = error as? LiveTranslateError {
            return liveError.localizedDescription
        }

        let nsError = error as NSError

        NSLog(
            "[SuperNotch] Live Translate failed: domain=%@ code=%ld message=%@",
            nsError.domain,
            nsError.code,
            nsError.localizedDescription
        )

        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            return "System audio capture gagal (SCStream error \(nsError.code)): \(nsError.localizedDescription)"
        }

        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }
}

@MainActor
private final class LiveTranslateShortcutCaptureView: NSView {
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Press a new shortcut")
    var captured: LiveTranslateShortcut?

    override var acceptsFirstResponder: Bool { true }

    init(current: LiveTranslateShortcut) {
        captured = current
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 74))

        shortcutLabel.stringValue = current.displayString
        shortcutLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        shortcutLabel.alignment = .center

        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor

        [shortcutLabel, hint].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            shortcutLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            shortcutLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: shortcutLabel.bottomAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let value = LiveTranslateShortcut(event: event),
              !value.conflictsWithFileShelf else {
            NSSound.beep()
            hint.stringValue = "Use modifier + key. Cmd+X / Cmd+V are reserved."
            return
        }

        captured = value
        shortcutLabel.stringValue = value.displayString
        hint.stringValue = "Ready to save"
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )
    }
}

private final class LiveTranslateStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let audioHandler: (CMSampleBuffer) -> Void

    init(audioHandler: @escaping (CMSampleBuffer) -> Void) {
        self.audioHandler = audioHandler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        audioHandler(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[SuperNotch] Live Translate capture stopped: %@", error.localizedDescription)
    }
}

private enum LiveTranslateError: LocalizedError {
    case speechPermission
    case speechUnavailable
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .speechPermission:
            return "Izinkan Speech Recognition untuk SuperNotch di System Settings → Privacy & Security."
        case .speechUnavailable:
            return "Speech Recognition sedang tidak tersedia."
        case .noDisplay:
            return "SuperNotch tidak menemukan display yang bisa dipakai untuk menangkap audio meeting."
        }
    }
}
