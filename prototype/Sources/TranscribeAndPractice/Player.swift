import AppKit
import AVFoundation
import CoreAudio
import os

/// State shared between the audio render callback and the main thread, guarded by a lock.
/// (A lock in the render callback isn't real-time safe; acceptable for the prototype.)
final class PlaybackCore: @unchecked Sendable {
    struct Segment { var cumulative: Int; var filePos: Int; var length: Int }

    private let lock = OSAllocatedUnfairLock()

    // Audio, as non-interleaved channel pointers (kept alive by `buffer`).
    private var buffer: AVAudioPCMBuffer?
    private var frames = 0

    // Shared playback state (frames of the file).
    private(set) var playing = false
    private var position = 0
    private(set) var startFrame = 0
    private var selection: (lo: Int, hi: Int)?
    private var loop = false
    private var startedInside = false
    private var startedAtStart = false
    /// Set by the render thread when playback ended by itself; the target to rewind to.
    private var endedRewind: Int?

    // Playhead bookkeeping: frames rendered since the playback started, and where they came from.
    private(set) var rendered = 0
    /// `rendered` at the start of the last callback that rendered audio.
    private(set) var lastBufferStart = 0
    private var segments: [Segment] = []
    private(set) var latencyFrames = 0
    private(set) var playheadFrame = 0
    private(set) var callbackCount = 0
    private(set) var playheadUpdates = 0
    private(set) var lastCallbackFrames = 0

    // Verification: recording of what is rendered while playing.
    private var recording: [[Float]]?

    func withLock<T>(_ body: () -> T) -> T { lock.withLockUnchecked(body) }

    func load(_ audio: LoadedAudio?) {
        withLock {
            buffer = audio?.buffer
            frames = audio?.frameCount ?? 0
            playing = false
            endedRewind = nil
            playheadFrame = 0
        }
    }

    func setLatency(frames: Int) { withLock { latencyFrames = frames } }
    func setLoop(_ on: Bool) { withLock { loop = on } }
    func setSelection(_ s: (lo: Int, hi: Int)?) { withLock { selection = s } }

    /// Starts playing at `frame`; decides the selection rules for this playback.
    func start(at frame: Int, selection sel: (lo: Int, hi: Int)?, loop: Bool) {
        withLock {
            position = min(max(frame, 0), frames)
            startFrame = position
            selection = sel
            self.loop = loop
            startedInside = sel.map { $0.lo <= position && position < $0.hi } ?? false
            startedAtStart = sel.map { abs(position - $0.lo) <= 1 } ?? false
            rendered = 0
            segments = []
            endedRewind = nil
            playheadFrame = position
            playing = true
        }
    }

    /// Stops; returns the playhead (audible position) at the moment of stopping.
    func stop() -> Int {
        withLock {
            playing = false
            return playheadFrame
        }
    }

    /// If playback ended by itself since the last call: the frame to rewind the playhead to.
    func takeEnded() -> Int? {
        withLock {
            defer { endedRewind = nil }
            return endedRewind
        }
    }

    func startRecording() { withLock { recording = [[], []] } }
    func stopRecording() -> [[Float]] {
        withLock {
            defer { recording = nil }
            return recording ?? [[], []]
        }
    }

    /// Render callback body: fills `count` frames of the 2-channel output.
    func render(count: Int, into abl: UnsafeMutableAudioBufferListPointer) {
        withLock {
            callbackCount += 1
            lastCallbackFrames = count
            let out = abl.map { $0.mData!.assumingMemoryBound(to: Float.self) }
            var done = 0
            if playing, let data = buffer?.floatChannelData {
                let channels = Int(buffer!.format.channelCount)
                let bufferStart = rendered
                lastBufferStart = bufferStart
                while done < count, playing {
                    // The selection end applies only when crossed from before it.
                    var limit = frames
                    var atSelectionEnd = false
                    if let sel = selection, position < sel.hi,
                       (loop && startedInside) || (!loop && startedAtStart) {
                        limit = sel.hi
                        atSelectionEnd = true
                    }
                    let n = min(count - done, limit - position)
                    if n > 0 {
                        for c in 0..<out.count {
                            let src = data[min(c, channels - 1)] + position
                            (out[c] + done).update(from: src, count: n)
                        }
                        if recording != nil {
                            for c in 0..<2 {
                                recording![c].append(contentsOf: UnsafeBufferPointer(start: data[min(c, channels - 1)] + position, count: n))
                            }
                        }
                        segments.append(Segment(cumulative: rendered, filePos: position, length: n))
                        if segments.count > 512 { segments.removeFirst(segments.count - 256) }
                        position += n
                        rendered += n
                        done += n
                    }
                    if position >= limit {
                        if atSelectionEnd, loop, startedInside, let sel = selection {
                            position = sel.lo
                        } else {
                            playing = false
                            endedRewind = atSelectionEnd ? (selection?.lo ?? 0) : 0
                        }
                    }
                }
                // Playhead: the start of this buffer minus the output latency, mapped back to
                // the file position through the rendered segments.
                let audible = bufferStart - latencyFrames
                if playing || endedRewind == nil {
                    playheadFrame = filePosition(atRendered: audible)
                    playheadUpdates += 1
                }
            }
            for c in 0..<out.count where done < count {
                (out[c] + done).update(repeating: 0, count: count - done)
            }
        }
    }

    private func filePosition(atRendered r: Int) -> Int {
        guard r > 0, let seg = segments.last(where: { $0.cumulative <= r }) else { return startFrame }
        return seg.filePos + min(r - seg.cumulative, seg.length)
    }
}

/// Audio output: AVAudioEngine with a source node that renders from PlaybackCore.
@MainActor
final class Player {
    let core = PlaybackCore()
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var sampleRate: Double = 44100

    /// Output device facts, for the playhead latency and the state dump.
    private(set) var ioBufferFrames = 0
    private(set) var deviceSampleRate: Double = 0
    private(set) var latencySeconds: Double = 0
    private(set) var refreshRate: Double = 0
    private(set) var targetBufferSeconds: Double = 0

    func load(_ audio: LoadedAudio?) {
        core.load(audio)
        guard let audio else { return }
        if source == nil || audio.sampleRate != sampleRate {
            sampleRate = audio.sampleRate
            if let source {
                engine.disconnectNodeOutput(source)
                engine.detach(source)
            }
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            let node = AVAudioSourceNode(format: format, renderBlock: Self.renderBlock(core))
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node
        }
    }

    /// The render block must not be main-actor isolated: it runs on the audio thread, and Swift
    /// checks the isolation at run time.
    private nonisolated static func renderBlock(_ core: PlaybackCore) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, abl -> OSStatus in
            core.render(count: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
    }

    /// Starts the engine (once) after configuring the device buffer size.
    func ensureRunning() {
        guard !engine.isRunning, source != nil else { return }
        configureDevice()
        do {
            try engine.start()
        } catch {
            FileHandle.standardError.write(Data("audio engine failed to start: \(error)\n".utf8))
        }
        updateLatency()
    }

    /// Smallest multiple of the display refresh period that is ≥ 30 ms (limited to 30–50 ms);
    /// 40 ms without a known refresh rate.
    static func bufferSeconds(refreshRate: Double) -> Double {
        guard refreshRate > 0 else { return 0.04 }
        let period = 1 / refreshRate
        let k = (0.03 / period - 1e-9).rounded(.up)
        let t = k * period
        return t <= 0.05 ? t : 0.04
    }

    private func configureDevice() {
        refreshRate = Double(NSScreen.main?.maximumFramesPerSecond ?? 0)
        targetBufferSeconds = Self.bufferSeconds(refreshRate: refreshRate)
        guard let device = defaultOutputDevice() else { return }
        deviceSampleRate = getDouble(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) ?? 0
        guard deviceSampleRate > 0 else { return }
        var frames = UInt32((targetBufferSeconds * deviceSampleRate).rounded())
        if let range: AudioValueRange = getValue(device, kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal) {
            frames = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        // The engine renders at most maximumFramesToRender per call; allow the whole buffer.
        engine.outputNode.auAudioUnit.maximumFramesToRender = max(4096, frames * 2)
    }

    /// Output latency: device latency + safety offset + stream latency + I/O buffer.
    func updateLatency() {
        guard let device = defaultOutputDevice() else { return }
        let scope = kAudioObjectPropertyScopeOutput
        let latency: UInt32 = getValue(device, kAudioDevicePropertyLatency, scope) ?? 0
        let safety: UInt32 = getValue(device, kAudioDevicePropertySafetyOffset, scope) ?? 0
        let buffer: UInt32 = getValue(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal) ?? 0
        var streamLatency: UInt32 = 0
        if let streams: [AudioStreamID] = getArray(device, kAudioDevicePropertyStreams, scope), let first = streams.first {
            streamLatency = getValue(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) ?? 0
        }
        ioBufferFrames = Int(buffer)
        deviceSampleRate = getDouble(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) ?? deviceSampleRate
        guard deviceSampleRate > 0 else { return }
        latencySeconds = Double(latency + safety + streamLatency + buffer) / deviceSampleRate
        core.setLatency(frames: Int((latencySeconds * sampleRate).rounded()))
    }

    // MARK: Core Audio property helpers

    private func defaultOutputDevice() -> AudioObjectID? {
        let id: AudioObjectID? = getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                          kAudioObjectPropertyScopeGlobal)
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private func getValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, p) == noErr else { return nil }
        return p.pointee
    }

    private func getDouble(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope) -> Double? {
        let v: Float64? = getValue(object, selector, scope)
        return v
    }

    private func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope) -> [T]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<T>.stride
        let p = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, p) == noErr else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: count))
    }
}

/// Writes 2-channel float samples as a 32-bit float WAV file (verification hook).
func writeFloatWAV(path: String, channels: [[Float]], sampleRate: Double) throws {
    let n = channels.map(\.count).min() ?? 0
    let ch = channels.count
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let payload = UInt32(n * ch * 4)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + payload); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(UInt16(ch)); u32(UInt32(sampleRate))
    u32(UInt32(sampleRate) * UInt32(ch) * 4); u16(UInt16(ch * 4)); u16(32)
    data.append(contentsOf: Array("data".utf8)); u32(payload)
    var interleaved = [Float](repeating: 0, count: n * ch)
    for i in 0..<n { for c in 0..<ch { interleaved[i * ch + c] = channels[c][i] } }
    interleaved.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: URL(fileURLWithPath: path))
}
