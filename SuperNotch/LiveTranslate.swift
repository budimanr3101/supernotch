import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech
import Translation

@MainActor
final class SuperNotchLiveTranslateFeature: NSObject {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case failed(String)
    }

    var onCaption: ((String, String, Bool) -> Void)?
    var onStateChanged: ((State) -> Void)?

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
    private var translationTask: Task<Void, Never>?
    private var lastRequestedText = ""
    private var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    var isRunning: Bool {
        switch state {
        case .starting, .listening:
            return true
        case .idle, .failed:
            return false
        }
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
        onCaption?(text, "Translating…", true)

        guard text != lastRequestedText else { return }
        lastRequestedText = text

        translationTask?.cancel()
        let delay: UInt64 = isFinal ? 60_000_000 : 450_000_000

        translationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            await self.translate(text, isFinal: isFinal)
        }
    }

    private func translate(_ text: String, isFinal: Bool) async {
        do {
            let source = Locale.Language(identifier: "en")
            let target = Locale.Language(identifier: "id")
            let session = TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: .lowLatency
            )
            let response = try await session.translate(text)

            guard !Task.isCancelled else { return }
            onCaption?(text, response.targetText, !isFinal)
        } catch {
            guard !Task.isCancelled else { return }
            NSLog("[SuperNotch] Translation error: %@", error.localizedDescription)
            onCaption?(
                text,
                "Translation language pack belum siap. Buka app Translate sekali untuk memasang English ↔ Indonesian.",
                false
            )
        }
    }

    private func stopInternals() {
        translationTask?.cancel()
        translationTask = nil
        lastRequestedText = ""

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
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            return "SuperNotch butuh izin Screen & System Audio Recording untuk mendengar audio meeting."
        }

        return error.localizedDescription
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
