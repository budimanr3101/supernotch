import AVFoundation
import CoreAudio
import Foundation
@preconcurrency import Speech

/// HAL callback -> bounded copied PCM -> serial worker -> 16 kHz mono Speech.
/// All HAL setup, listener bookkeeping, request appends and teardown use worker.
/// The callback only calls the preallocated, lock-free C queue; it owns no UI.
final class LiveTranslateSystemAudioTap: @unchecked Sendable {
    private static let worker = DispatchQueue(label: "com.budiman.supernotch.audio-tap", qos: .userInitiated)
    private let maxFrames: UInt32 = 16_384
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var ring: OpaquePointer?
    private var bridge: LiveTranslatePCMBridge?
    private var timer: DispatchSourceTimer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var running = false
    private var selfProcess = AudioObjectID(kAudioObjectUnknown)
    private var rebuildPending = false
    private var generation: UInt64 = 0
    private var lastDropLog = Date.distantPast
    var onFailure: ((Error) -> Void)?
    var onDeviceChanged: (() -> Void)?

    func start(request: SFSpeechAudioBufferRecognitionRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.worker.async {
                do {
                    self.teardown()
                    self.generation &+= 1
                    self.request = request
                    try self.createHardware()
                    self.running = true
                    continuation.resume()
                } catch {
                    self.teardown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func replaceRequest(_ value: SFSpeechAudioBufferRecognitionRequest) {
        Self.worker.async {
            guard self.running else { value.endAudio(); return }
            self.request?.endAudio()
            self.request = value
        }
    }

    static func waitForCleanup() {
        worker.sync {}
    }

    func stop(wait: Bool = false) {
        let cleanup = {
            self.generation &+= 1
            self.running = false
            self.teardown()
        }
        // Only termination waits. Normal stop never blocks UI on a HAL/TCC call.
        if wait { Self.worker.sync(execute: cleanup) }
        else { Self.worker.async(execute: cleanup) }
    }

    private func createHardware() throws {
        NSLog("[SuperNotch] Live Translate capture API: Core Audio process tap (system audio only)")
        selfProcess = try processObject()
        let excluded = selfProcess == kAudioObjectUnknown ? [] : [selfProcess]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "SuperNotch Live Translate"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
        guard tapID != kAudioObjectUnknown else { throw SystemAudioTapError.invalidObject("tap") }
        NSLog("[SuperNotch] Live Translate process tap created; own process excluded=%d", !excluded.isEmpty ? 1 : 0)

        var asbd = AudioStreamBasicDescription()
        try read(tapID, kAudioTapPropertyFormat, into: &asbd)
        guard let format = AVAudioFormat(streamDescription: &asbd),
              asbd.mFormatID == kAudioFormatLinearPCM,
              format.commonFormat != .otherFormat,
              asbd.mSampleRate > 0, asbd.mSampleRate <= 192_000,
              asbd.mChannelsPerFrame > 0, asbd.mChannelsPerFrame <= 2,
              asbd.mBytesPerFrame > 0 else { throw SystemAudioTapError.format }
        bridge = try LiveTranslatePCMBridge(format: format)

        let output: AudioObjectID = try defaultOutput()
        let uid = try stringProperty(output, kAudioDevicePropertyDeviceUID)
        let tapUID = try stringProperty(tapID, kAudioTapPropertyUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SuperNotch Live Translate",
            kAudioAggregateDeviceUIDKey: "com.budiman.supernotch.live-translate." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "create aggregate device")
        guard deviceID != kAudioObjectUnknown else { throw SystemAudioTapError.invalidObject("aggregate") }

        // Tap-only aggregate: no physical subdevice input, so a headset's
        // microphone can never join capture. Its input format must match the tap.
        var aggregateFormat = AudioStreamBasicDescription()
        try read(deviceID, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput, into: &aggregateFormat)
        guard aggregateFormat.mSampleRate == asbd.mSampleRate,
              aggregateFormat.mFormatID == asbd.mFormatID,
              aggregateFormat.mFormatFlags == asbd.mFormatFlags,
              aggregateFormat.mChannelsPerFrame == asbd.mChannelsPerFrame,
              aggregateFormat.mBytesPerFrame == asbd.mBytesPerFrame else {
            throw SystemAudioTapError.format
        }
        let bufferCount: UInt32 = format.isInterleaved ? 1 : format.channelCount
        let channels: UInt32 = format.isInterleaved ? format.channelCount : 1
        guard let queue = SNPCMQueueCreate(bufferCount, channels, asbd.mBytesPerFrame, maxFrames) else {
            throw SystemAudioTapError.buffer
        }
        ring = queue
        // NULL dispatch queue invokes the block on HAL's IO thread. No Speech,
        // allocations, async dispatch, locks, logging, or borrowed pointers escape.
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, nil) { _, input, _, _, _ in
            SNPCMQueuePush(queue, input)
        }, "create IOProc")
        guard let ioProc = ioProc else { throw SystemAudioTapError.invalidObject("IOProc") }

        try listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        try listen(output, kAudioDevicePropertyNominalSampleRate)
        try listen(output, kAudioDevicePropertyDeviceIsAlive)
        try listen(tapID, kAudioTapPropertyFormat)
        try listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, processList: true)

        let timer = DispatchSource.makeTimerSource(queue: Self.worker)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer
        timer.resume()
        NSLog("[SuperNotch] Live Translate audio permission: requesting through AudioDeviceStart; no public TCC preflight")
        try check(AudioDeviceStart(deviceID, ioProc), "start audio-only device (check System Audio Recording Only permission)")
        NSLog("[SuperNotch] Live Translate audio device UID=%@ rate=%.0f channels=%u bits=%u interleaved=%d -> Speech 16000 Hz mono Float32",
              uid, format.sampleRate, format.channelCount, asbd.mBitsPerChannel, format.isInterleaved ? 1 : 0)
        // A successful HAL start is not proof of TCC authorization or non-silent
        // audio. Only real-Mac runtime testing can establish that.
    }

    private func drain() {
        guard running, let ring = ring, let bridge = bridge else { return }
        if SNPCMQueueTakeFault(ring) { fail(SystemAudioTapError.format); return }
        let drops = SNPCMQueueTakeDrops(ring)
        if drops > 0, Date().timeIntervalSince(lastDropLog) > 5 {
            lastDropLog = Date()
            NSLog("[SuperNotch] Live Translate PCM queue overflow: dropped %u audio chunks", drops)
        }
        // Bound a drain pass so control/device-change events cannot starve.
        for _ in 0..<32 {
            guard SNPCMQueueHasData(ring) else { break }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: bridge.inputFormat, frameCapacity: maxFrames) else {
                fail(SystemAudioTapError.buffer); return
            }
            // AVAudioPCMBuffer starts with frameLength=0 and zero byte sizes.
            // Publish allocated capacity before asking C to fill that storage.
            pcm.frameLength = maxFrames
            var frames: UInt32 = 0
            guard SNPCMQueueRead(ring, pcm.mutableAudioBufferList, maxFrames, &frames) else {
                fail(SystemAudioTapError.buffer); return
            }
            pcm.frameLength = frames
            guard let request = request else { continue }
            do {
                if let converted = try bridge.convert(pcm) { request.append(converted) }
            } catch { fail(error); return }
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        processList: Bool = false) throws {
        var address = Self.address(selector)
        let token = generation
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, self.running, self.generation == token else { return }
            if processList {
                // A global tap already includes newly launched meeting apps.
                // Rebuild only if our own process acquires a HAL object later.
                do {
                    guard try self.processObject() != self.selfProcess else { return }
                } catch { self.fail(error); return }
            }
            self.scheduleRebuild()
        }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, Self.worker, block), "add audio property listener")
        listeners.append((object, address, block))
    }

    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        let token = generation
        Self.worker.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self = self, self.running, self.generation == token else { return }
            NSLog("[SuperNotch] Live Translate audio output/format changed; rebuilding capture")
            self.teardown()
            self.generation &+= 1
            do {
                try self.createHardware()
                self.running = true
                self.onDeviceChanged?()
            } catch { self.fail(error) }
        }
    }

    private func fail(_ error: Error) {
        running = false
        generation &+= 1
        teardown()
        onFailure?(error)
    }

    private func teardown() {
        for (object, storedAddress, block) in listeners {
            var address = storedAddress
            cleanupStatus(AudioObjectRemovePropertyListenerBlock(object, &address, Self.worker, block), "remove listener")
        }
        listeners.removeAll()
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        var callbackDestroyed = ioProc == nil
        if let ioProc = ioProc {
            cleanupStatus(AudioDeviceStop(deviceID, ioProc), "stop IOProc")
            let status = AudioDeviceDestroyIOProcID(deviceID, ioProc)
            cleanupStatus(status, "destroy IOProc")
            callbackDestroyed = status == noErr
        }
        ioProc = nil
        if deviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(deviceID)
            cleanupStatus(status, "destroy aggregate")
            callbackDestroyed = callbackDestroyed || status == noErr
        }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            cleanupStatus(AudioHardwareDestroyProcessTap(tapID), "destroy tap")
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        // HAL can no longer access the queue.
        if let ring = ring {
            if callbackDestroyed { SNPCMQueueDestroy(ring) }
            else {
                // Catastrophic HAL teardown failure: retain bounded storage rather
                // than free memory which an outstanding IOProc could still access.
                NSLog("[SuperNotch] Live Translate HAL teardown failed; PCM storage retained for callback safety")
            }
        }
        ring = nil
        bridge = nil
        request?.endAudio()
        request = nil
        rebuildPending = false
        NSLog("[SuperNotch] Live Translate audio tap cleanup completed")
    }

    private func processObject() throws -> AudioObjectID {
        var pid = getpid()
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &result), "resolve own audio process")
        return result
    }

    private func defaultOutput() throws -> AudioObjectID {
        var result = AudioObjectID(kAudioObjectUnknown)
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &result)
        guard result != kAudioObjectUnknown else { throw SystemAudioTapError.invalidObject("default output") }
        return result
    }

    private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = Self.address(selector)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, "read device/tap UID")
        return value as String
    }

    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) throws {
        var address = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        // Only fixed-size imported C structs/scalars are passed by this service.
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, "read audio property \(selector)")
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SystemAudioTapError.hal(operation, status) }
    }

    private func cleanupStatus(_ status: OSStatus, _ operation: String) {
        if status != noErr {
            NSLog("[SuperNotch] Live Translate HAL cleanup: %@ OSStatus=%d", operation, status)
        }
    }
}

/// Conversion happens exclusively on the worker, after copying HAL-owned memory.
final class LiveTranslatePCMBridge {
    let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(format: AVAudioFormat) throws {
        inputFormat = format
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw SystemAudioTapError.format
        }
        outputFormat = output
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / inputFormat.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw SystemAudioTapError.buffer
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let error = error { throw error }
        guard status != .error else { throw SystemAudioTapError.format }
        return output.frameLength > 0 ? output : nil
    }
}

enum SystemAudioTapError: LocalizedError {
    case hal(String, OSStatus)
    case invalidObject(String)
    case format
    case buffer

    var errorDescription: String? {
        switch self {
        case .hal(let operation, let status):
            return "Core Audio: \(operation), OSStatus \(status). Jika akses audio ditolak, izinkan SuperNotch di Privacy & Security → System Audio Recording Only."
        case .invalidObject(let name):
            return "Core Audio tidak menemukan \(name). Periksa perangkat output audio."
        case .format:
            return "Format PCM system audio berubah atau tidak didukung. Coba mulai Live Translate lagi."
        case .buffer:
            return "Buffer system audio tidak dapat diproses."
        }
    }
}
