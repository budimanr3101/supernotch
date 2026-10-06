import AVFoundation
import Foundation

// No TCC or live audio required: exercise the real PCM queue and converter.
@main
struct LiveTranslateAudioTests {
    static func main() throws {
        for interleaved in [false, true] {
            for rate in [44_100.0, 48_000.0, 96_000.0] {
                try queueAndConversion(rate: rate, interleaved: interleaved)
            }
        }
        print("PASS: copied PCM lifetime, planar/interleaved stereo, bounded overflow, invalid input, 44.1/48/96 kHz -> 16 kHz mono")
    }

    static func queueAndConversion(rate: Double, interleaved: Bool) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 2, interleaved: interleaved)!
        let frames: UInt32 = 4096
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        input.frameLength = frames
        let list = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let count: UInt32 = interleaved ? 1 : 2
        let channels: UInt32 = interleaved ? 2 : 1
        let bytesPerFrame: UInt32 = interleaved ? 8 : 4
        let q = SNPCMQueueCreate(count, channels, bytesPerFrame, frames)!
        defer { SNPCMQueueDestroy(q) }

        // Constant amplitude is easy to verify even with sample-rate conversion.
        for b in list {
            let p = b.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(b.mDataByteSize / 4) { p[i] = 0.25 }
        }
        SNPCMQueuePush(q, input.audioBufferList)
        // HAL reuses its memory immediately. The copied queue must stay intact.
        for b in list { memset(b.mData!, 0, Int(b.mDataByteSize)) }
        let copied = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        copied.frameLength = frames
        var readFrames: UInt32 = 0
        precondition(SNPCMQueueRead(q, copied.mutableAudioBufferList, frames, &readFrames))
        copied.frameLength = readFrames
        precondition(readFrames == frames)
        for b in UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList) {
            let p = b.mData!.assumingMemoryBound(to: Float.self)
            precondition(p[0] == 0.25 && p[Int(b.mDataByteSize / 4) - 1] == 0.25)
        }
        precondition(!SNPCMQueueHasData(q))
        let bridge = try LiveTranslatePCMBridge(format: format)
        let output = try bridge.convert(copied)!
        precondition(output.format.sampleRate == 16_000 && output.format.channelCount == 1)
        precondition(output.format.commonFormat == .pcmFormatFloat32 && !output.format.isInterleaved)
        precondition(output.frameLength > 0 && output.frameLength <= output.frameCapacity)
        let expectedFrames = Double(frames) * 16_000 / rate
        precondition(abs(Double(output.frameLength) - expectedFrames) < 128)
        let samples = output.floatChannelData![0]
        precondition(abs(samples[Int(output.frameLength / 2)] - 0.25) < 0.03)

        for _ in 0..<33 { SNPCMQueuePush(q, input.audioBufferList) }
        precondition(SNPCMQueueTakeDrops(q) == 1)
        for _ in 0..<32 {
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            out.frameLength = frames
            precondition(SNPCMQueueRead(q, out.mutableAudioBufferList, frames, &readFrames))
        }
        precondition(!SNPCMQueueHasData(q))
        // Reject a malformed byte size instead of copying beyond allocation.
        list[0].mDataByteSize = frames * bytesPerFrame + 1
        // Use the borrowed list directly: AVAudioPCMBuffer.audioBufferList
        // refreshes byte sizes from frameLength when fetched again.
        SNPCMQueuePush(q, list.unsafeMutablePointer)
        precondition(SNPCMQueueTakeFault(q))
        precondition(!SNPCMQueueHasData(q))
    }
}
