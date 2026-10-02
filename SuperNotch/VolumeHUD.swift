import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import Foundation

private enum SuperNotchMediaKey {
    static let soundUp = 0
    static let soundDown = 1
    static let mute = 7

    struct Event {
        let keyCode: Int
        let isKeyDown: Bool
    }

    static func parse(_ event: NSEvent) -> Event? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == 8 else {
            return nil
        }

        let data = event.data1
        let keyCode = (data & 0xFFFF0000) >> 16
        let keyState = (data & 0x0000FF00) >> 8

        guard keyCode == soundUp || keyCode == soundDown || keyCode == mute else {
            return nil
        }

        return Event(
            keyCode: keyCode,
            isKeyDown: keyState == 0x0A
        )
    }
}

private struct SuperNotchVolumeSnapshot {
    let level: Double
    let muted: Bool
}

private enum SuperNotchSystemVolume {
    private static let step: Float32 = 1.0 / 16.0

    static func adjust(for keyCode: Int) -> SuperNotchVolumeSnapshot? {
        switch keyCode {
        case SuperNotchMediaKey.soundUp:
            guard let current = snapshot() else { return nil }
            let next = min(1, Float32(current.level) + step)
            guard setVolume(next) else { return nil }
            _ = setMuted(false)
            return snapshot() ?? SuperNotchVolumeSnapshot(level: Double(next), muted: false)

        case SuperNotchMediaKey.soundDown:
            guard let current = snapshot() else { return nil }
            let next = max(0, Float32(current.level) - step)
            guard setVolume(next) else { return nil }
            _ = setMuted(false)
            return snapshot() ?? SuperNotchVolumeSnapshot(level: Double(next), muted: false)

        case SuperNotchMediaKey.mute:
            guard let current = snapshot() else { return nil }
            guard setMuted(!current.muted) else {
                return toggleMuteWithAppleScript()
            }
            return snapshot() ?? SuperNotchVolumeSnapshot(level: current.level, muted: !current.muted)

        default:
            return nil
        }
    }

    static func snapshot() -> SuperNotchVolumeSnapshot? {
        if let device = defaultOutputDevice(),
           let level = readVolume(device: device) {
            let muted = readMuted(device: device) ?? readMutedWithAppleScript() ?? false
            return SuperNotchVolumeSnapshot(
                level: Double(max(0, min(1, level))),
                muted: muted
            )
        }

        return snapshotWithAppleScript()
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )

        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func readVolume(device: AudioDeviceID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(device, &address) else {
            return nil
        }

        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private static func setVolume(_ value: Float32) -> Bool {
        if let device = defaultOutputDevice() {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var clamped = max(0, min(1, value))
            let status = AudioObjectSetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &clamped
            )
            if status == noErr {
                return true
            }
        }

        let percent = Int((max(0, min(1, value)) * 100).rounded())
        return runAppleScript("set volume output volume \(percent)") != nil
    }

    private static func readMuted(device: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(device, &address) else {
            return nil
        }

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value != 0 : nil
    }

    private static func setMuted(_ muted: Bool) -> Bool {
        if let device = defaultOutputDevice() {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(device, &address) {
                var value: UInt32 = muted ? 1 : 0
                let status = AudioObjectSetPropertyData(
                    device,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<UInt32>.size),
                    &value
                )
                if status == noErr {
                    return true
                }
            }
        }

        return runAppleScript("set volume \(muted ? "with" : "without") output muted") != nil
    }

    private static func snapshotWithAppleScript() -> SuperNotchVolumeSnapshot? {
        guard let output = runAppleScript("output volume of (get volume settings)"),
              let level = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        let muted = readMutedWithAppleScript() ?? false
        return SuperNotchVolumeSnapshot(
            level: max(0, min(1, level / 100)),
            muted: muted
        )
    }

    private static func readMutedWithAppleScript() -> Bool? {
        guard let output = runAppleScript("output muted of (get volume settings)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }
        if output == "true" { return true }
        if output == "false" { return false }
        return nil
    }

    private static func toggleMuteWithAppleScript() -> SuperNotchVolumeSnapshot? {
        guard let current = snapshotWithAppleScript() else { return nil }
        guard runAppleScript("set volume \(current.muted ? "without" : "with") output muted") != nil else {
            return nil
        }
        return snapshotWithAppleScript()
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

final class SuperNotchVolumeHUDFeature {
    private static let accessibilityPromptedKey = "SuperNotch.volumeHUDAccessibilityPrompted"
    private static let enabledFeaturesKey = "SuperNotch.enabledFeatures"
    private static let featureSchemaKey = "SuperNotch.featureSchemaVersion"
    private static let volumeFeatureSchemaVersion = 2

    var onVolumeChanged: ((Double, Bool) -> Void)?

    private let stateLock = NSLock()
    private var enabled = true
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        refreshEnabledState()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.refreshEnabledState()
        }

        configureInputHandling()
    }

    func stop() {
        started = false
        permissionTimer?.invalidate()
        permissionTimer = nil

        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }

        removeActiveTap()
        removeFallbackMonitor()
    }

    private func refreshEnabledState() {
        let defaults = UserDefaults.standard
        let schema = defaults.integer(forKey: Self.featureSchemaKey)
        let saved = defaults.stringArray(forKey: Self.enabledFeaturesKey) ?? []
        let nextEnabled = schema < Self.volumeFeatureSchemaVersion
            || saved.isEmpty
            || saved.contains(SuperNotchFeatureID.volumeHUD.rawValue)

        stateLock.lock()
        let changed = enabled != nextEnabled
        enabled = nextEnabled
        stateLock.unlock()

        guard changed, started else { return }
        configureInputHandling()
    }

    private func isEnabled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return enabled
    }

    private func configureInputHandling() {
        guard isEnabled() else {
            removeActiveTap()
            removeFallbackMonitor()
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }

        if AXIsProcessTrusted() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            removeFallbackMonitor()
            installActiveTap()
        } else {
            removeActiveTap()
            installFallbackMonitor()
            requestAccessibilityPermissionOnce()
            startPermissionPolling()
        }
    }

    private func installActiveTap() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1) << 14
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let owner = Unmanaged<SuperNotchVolumeHUDFeature>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return owner.handleTapEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            installFallbackMonitor()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[SuperNotch] Volume HUD is replacing macOS media-key volume OSD")
    }

    private func removeActiveTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    private func handleTapEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled(),
              let nsEvent = NSEvent(cgEvent: event),
              let mediaEvent = SuperNotchMediaKey.parse(nsEvent) else {
            return Unmanaged.passUnretained(event)
        }

        if mediaEvent.isKeyDown,
           let snapshot = SuperNotchSystemVolume.adjust(for: mediaEvent.keyCode) {
            DispatchQueue.main.async { [weak self] in
                self?.onVolumeChanged?(snapshot.level, snapshot.muted)
            }
        }

        // Swallow recognized media-key down/up events so macOS does not draw its
        // own volume HUD. SuperNotch becomes the visual owner while it is running.
        return nil
    }

    private func installFallbackMonitor() {
        guard fallbackMonitor == nil else { return }

        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in
            guard let self,
                  self.isEnabled(),
                  let mediaEvent = SuperNotchMediaKey.parse(event),
                  mediaEvent.isKeyDown else {
                return
            }

            // Without Accessibility permission we cannot suppress Apple's OSD.
            // Read the resulting system volume a moment later so the SuperNotch
            // HUD still reflects the real value while permission is pending.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let snapshot = SuperNotchSystemVolume.snapshot() else { return }
                self?.onVolumeChanged?(snapshot.level, snapshot.muted)
            }
        }
    }

    private func removeFallbackMonitor() {
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }
    }

    private func requestAccessibilityPermissionOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.accessibilityPromptedKey) else { return }
        defaults.set(true, forKey: Self.accessibilityPromptedKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.started, self.isEnabled() else { return }
            if AXIsProcessTrusted() {
                self.configureInputHandling()
            }
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
