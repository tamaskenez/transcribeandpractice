import AVFoundation
import Accelerate

/// Peak and RMS level of one channel, in dBFS. `nil` means silence (-infinity dB).
struct ChannelStats: Codable {
    let peakDBFS: Double?
    let rmsDBFS: Double?
}

/// A fully decoded audio file: all channels, file's own sample rate, Float32, non-interleaved.
struct LoadedAudio {
    let url: URL
    let buffer: AVAudioPCMBuffer
    let channelStats: [ChannelStats]

    var fileName: String { url.lastPathComponent }
    var sampleRate: Double { buffer.format.sampleRate }
    var channelCount: Int { Int(buffer.format.channelCount) }
    var frameCount: Int { Int(buffer.frameLength) }
    var duration: Double { Double(frameCount) / sampleRate }
}

enum AudioLoadError: LocalizedError {
    case empty
    case cannotAllocate
    case truncated(expected: Int64, actual: Int)

    var errorDescription: String? {
        switch self {
        case .empty: return "The file contains no audio."
        case .cannotAllocate: return "Not enough memory to decode the file."
        case let .truncated(expected, actual):
            return "The file is truncated or damaged (expected \(expected) frames, decoded \(actual))."
        }
    }
}

enum AudioLoader {
    static func load(url: URL) throws -> LoadedAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let length = file.length
        guard length > 0 else { throw AudioLoadError.empty }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(length)) else {
            throw AudioLoadError.cannotAllocate
        }
        // A single read(into:) may return fewer frames than requested (e.g. CAF), so read in chunks.
        let chunkSize: AVAudioFrameCount = 65536
        guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize),
              let dst = buffer.floatChannelData, let src = chunk.floatChannelData else {
            throw AudioLoadError.cannotAllocate
        }
        let channels = Int(file.processingFormat.channelCount)
        var total = 0
        while Int64(total) < length {
            let want = AVAudioFrameCount(min(Int64(chunkSize), length - Int64(total)))
            try file.read(into: chunk, frameCount: want)
            let got = Int(chunk.frameLength)
            if got == 0 { break }
            for ch in 0..<channels {
                (dst[ch] + total).update(from: src[ch], count: got)
            }
            total += got
        }
        buffer.frameLength = AVAudioFrameCount(total)
        if Int64(total) < length {
            throw AudioLoadError.truncated(expected: length, actual: total)
        }
        return LoadedAudio(url: url, buffer: buffer, channelStats: stats(of: buffer))
    }

    private static func stats(of buffer: AVAudioPCMBuffer) -> [ChannelStats] {
        guard let data = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { ch in
            let samples = UnsafeBufferPointer(start: data[ch], count: n)
            return ChannelStats(peakDBFS: dB(Double(vDSP.maximumMagnitude(samples))),
                                rmsDBFS: dB(Double(vDSP.rootMeanSquare(samples))))
        }
    }

    private static func dB(_ x: Double) -> Double? { x > 0 ? 20 * log10(x) : nil }
}
