import AppKit
import Carbon.HIToolbox
import Foundation
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
    private var capture: LiveTranslateSystemAudioTap?
    private var startTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var recognitionID = UUID()
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

        let token = UUID()
        sessionID = token
        state = .starting
        onCaption?("", "Starting Live Translate…", true)
        NSLog("[SuperNotch] Live Translate starting")

        startTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.authorizeSpeech()
                try Task.checkCancellation()
                guard self.sessionID == token else { return }

                let capture = LiveTranslateSystemAudioTap()
                self.capture = capture
                capture.onFailure = { [weak self] error in
                    Task { @MainActor in
                        guard let self = self, self.sessionID == token else { return }
                        self.fail(error)
                    }
                }
                capture.onDeviceChanged = { [weak self] in
                    Task { @MainActor in
                        guard let self = self, self.sessionID == token, self.isRunning else { return }
                        do {
                            let request = try self.startRecognition(session: token)
                            self.capture?.replaceRequest(request)
                        } catch { self.fail(error) }
                    }
                }
                let request = try self.startRecognition(session: token)
                try await capture.start(request: request)
                try Task.checkCancellation()
                guard self.sessionID == token else { return }
                self.state = .listening
                self.onCaption?("", "Listening to system audio…", true)
            } catch {
                guard self.sessionID == token, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    func stop(waitForCleanup: Bool = false) {
        stopInternals(wait: waitForCleanup)
        state = .idle
    }

    private func fail(_ error: Error) {
        let message = userFacingMessage(for: error)
        stopInternals()
        state = .failed(message)
        onCaption?("", message, false)
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

    private func startRecognition(session token: UUID) throws -> SFSpeechAudioBufferRecognitionRequest {
        renewalTask?.cancel()
        recognitionID = UUID()
        let speechToken = recognitionID
        recognitionTask?.cancel()
        // Capture owns append/endAudio on its serial worker. Cancelling this task
        // does not race a request mutation on MainActor.
        recognitionRequest = nil
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw LiveTranslateError.speechUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.addsPunctuation = true
        recognitionRequest = request
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            // Extract values before hopping actors; never log transcript text.
            let text = result?.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let final = result?.isFinal == true
            Task { @MainActor in
                guard let self = self, self.sessionID == token,
                      self.recognitionID == speechToken, self.isRunning else { return }
                if let text = text, !text.isEmpty {
                    self.onCaption?(text, "", !final)
                }
                if final {
                    self.renewRecognition(session: token)
                } else if let error = error {
                    self.fail(error)
                }
            }
        }
        NSLog("[SuperNotch] Live Translate Speech recognizer started (en-US, streaming partials)")
        // Apple's online Speech tasks are time-limited. Rotate before one minute
        // rather than silently abandoning recognition during a long meeting.
        renewalTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 50_000_000_000) }
            catch { return }
            guard let self = self, self.sessionID == token,
                  self.recognitionID == speechToken, self.isRunning else { return }
            self.renewRecognition(session: token)
        }
        return request
    }

    private func renewRecognition(session token: UUID) {
        do {
            let request = try startRecognition(session: token)
            capture?.replaceRequest(request)
        } catch { fail(error) }
    }

    private func stopInternals(wait: Bool = false) {
        sessionID = UUID()
        recognitionID = UUID()
        startTask?.cancel()
        startTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        capture?.stop(wait: wait)
        capture = nil
        if wait { LiveTranslateSystemAudioTap.waitForCleanup() }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        NSLog("[SuperNotch] Live Translate Speech recognizer stopped")
    }

    private func userFacingMessage(for error: Error) -> String {
        if let liveError = error as? LiveTranslateError {
            return liveError.localizedDescription
        }

        if let tapError = error as? SystemAudioTapError {
            NSLog("[SuperNotch] Live Translate Core Audio failure: %@", tapError.localizedDescription)
            return tapError.localizedDescription
        }

        let nsError = error as NSError

        // Error descriptions can contain service payloads; log only domain/code.
        NSLog("[SuperNotch] Live Translate failed: domain=%@ code=%ld", nsError.domain, nsError.code)
        return "Speech/audio service failed: \(nsError.domain) (\(nsError.code)). Check connectivity and try Start again."
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

private enum LiveTranslateError: LocalizedError {
    case speechPermission
    case speechUnavailable

    var errorDescription: String? {
        switch self {
        case .speechPermission:
            return "Izinkan Speech Recognition untuk SuperNotch di System Settings → Privacy & Security."
        case .speechUnavailable:
            return "Speech Recognition sedang tidak tersedia."
        }
    }
}
