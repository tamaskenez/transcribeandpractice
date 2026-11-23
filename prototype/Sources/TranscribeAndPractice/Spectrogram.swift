import Accelerate
import AppKit

/// Main pane view mode (milestone 8).
enum MainPaneMode: String, CaseIterable { case waveform, spectrogram }

enum SpectrogramConstants {
    static let fftLength = 65536
    static let log2FFTLength: vDSP_Length = 16
    /// Gaussian α of MATLAB's default `gausswin`.
    static let alpha = 2.5
    /// Frequency axis: A0 (MIDI 21) − ½ … C9 (MIDI 120) + ½.
    static let lowestNote = 21, highestNote = 120
    static let rangeSemitones = Double(highestNote - lowestNote + 1)
    static let pointsPerSemitone = 14.0
    /// Middle of C4's semitone, from the range's low edge.
    static let c4Position = Double(60 - lowestNote) + 0.5
    /// Displayed level range at amplitude zoom ×1 (dB).
    static let displayLow = -60.0, displayHigh = 0.0
    /// Columns computed per background step (results are shown after each step).
    static let chunk = 48
    /// Verification aid: extra delay (ms) per computed chunk, so the busy state can be observed.
    nonisolated(unsafe) static var testDelayMs = 0

    /// Frequency (Hz) of a position in semitones above the range's low edge.
    static func frequency(atSemitone s: Double) -> Double {
        440 * pow(2, (Double(lowestNote) - 0.5 + s - 69) / 12)
    }

    /// Odd window length for a slider value (seconds): σ = L/2, N = 2α·σ·fs + 1, cut to the FFT.
    static func windowLength(seconds: Double, sampleRate: Double) -> Int {
        let n = 2 * alpha * (seconds / 2) * sampleRate + 1
        let odd = 2 * Int(((n - 1) / 2).rounded()) + 1
        return min(odd, fftLength - 1)
    }

    static func gaussian(_ n: Int) -> [Double] {
        let half = Double(n - 1) / 2
        return (0..<n).map { k in
            let x = alpha * (Double(k) - half) / max(half, 1)
            return exp(-0.5 * x * x)
        }
    }
}

/// Everything a background job needs (immutable, sendable).
struct SpectrogramJobInput: Sendable {
    let mono: [Float]
    let window: [Double]
    let windowSum: Double
    /// FFT bin position of each row of the whole frequency range (low to high).
    let binPositions: [Double]
}

/// Computes the level columns (dB, before the amplitude zoom) for the given centre samples.
nonisolated func computeSpectrogramColumns(_ input: SpectrogramJobInput, centres: [Int]) -> [[Float]] {
    let n = SpectrogramConstants.fftLength
    let rows = input.binPositions.count
    final class Results: @unchecked Sendable { var columns: [[Float]]; init(_ n: Int) { columns = Array(repeating: [], count: n) } }
    let out = Results(centres.count)
    let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, centres.count))
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: workers) { worker in
        guard let setup = vDSP_create_fftsetupD(SpectrogramConstants.log2FFTLength, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetupD(setup) }
        var frame = [Double](repeating: 0, count: n)
        var re = [Double](repeating: 0, count: n / 2), im = [Double](repeating: 0, count: n / 2)
        var mag = [Double](repeating: 0, count: n / 2 + 1)
        let w = input.window, wn = w.count, h = (wn - 1) / 2
        let frames = input.mono.count
        let scale = 2 / input.windowSum
        var i = worker
        while i < centres.count {
            let c = centres[i]
            // Windowed samples at the buffer start, zero-padded (zero outside the file).
            frame.withUnsafeMutableBufferPointer { f in
                input.mono.withUnsafeBufferPointer { x in
                    for k in 0..<wn {
                        let s = c - h + k
                        f[k] = s >= 0 && s < frames ? Double(x[s]) * w[k] : 0
                    }
                    for k in wn..<n { f[k] = 0 }
                }
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: n / 2) {
                            vDSP_ctozD($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zripD(setup, &split, 1, SpectrogramConstants.log2FFTLength, FFTDirection(kFFTDirection_Forward))
                    // zrip's output is twice the DFT; packed: DC in realp[0], Nyquist in imagp[0].
                    mag.withUnsafeMutableBufferPointer { m in
                        m[0] = abs(rp[0]) / 2
                        m[n / 2] = abs(ip[0]) / 2
                        for k in 1..<(n / 2) { m[k] = (rp[k] * rp[k] + ip[k] * ip[k]).squareRoot() / 2 }
                    }
                }
            }
            var col = [Float](repeating: 0, count: rows)
            mag.withUnsafeBufferPointer { m in
                for r in 0..<rows {
                    let b = input.binPositions[r]
                    let i0 = min(Int(b), n / 2 - 1)
                    let t = b - Double(i0)
                    let v = m[i0] * (1 - t) + m[i0 + 1] * t
                    col[r] = Float(20 * log10(max(v * scale, 1e-30)))
                }
            }
            lock.lock(); out.columns[i] = col; lock.unlock()
            i += workers
        }
    }
    return out.columns
}

/// Spectrogram columns: cache, background computation and the rendered image.
@MainActor
final class SpectrogramEngine {
    /// What the cached columns depend on.
    struct Params: Equatable {
        var loadID: Int
        var sampleRate: Double
        var windowLength: Int
        var rowsPerSemitone: Double
        var secondsPerPixel: Double

        func sameScale(_ o: Params) -> Bool {
            loadID == o.loadID && sampleRate == o.sampleRate && windowLength == o.windowLength
                && rowsPerSemitone == o.rowsPerSemitone
                && abs(secondsPerPixel - o.secondsPerPixel) <= 1e-9 * o.secondsPerPixel
        }
    }

    /// The visible part: columns `firstColumn ..< firstColumn + columns` of the cache's grid, rows
    /// `firstRow ..< firstRow + rows` of the whole frequency range.
    struct Layout: Equatable {
        var firstColumn: Int
        var columns: Int
        var firstRow: Int
        var rows: Int
    }

    private(set) var params: Params?
    /// Grid origin: column k is centred at origin + (k + ½)·secondsPerPixel.
    private(set) var origin: Double = 0
    private var columns: [Int: [Float]] = [:]
    private var totalRows = 0
    private var generation = 0
    private var input: SpectrogramJobInput?
    private var queue: [(k: Int, sample: Int)] = []
    private var pending: Set<Int> = []
    private var running = false
    /// Columns computed since launch.
    private(set) var computedColumns = 0
    var cachedColumns: Int { columns.count }
    private(set) var layout: Layout?
    private(set) var complete = false

    /// The image last rendered completely, with its mapping, shown stretched while new columns
    /// are being computed.
    struct Picture {
        var image: CGImage
        var start: Double          // time of the image's first column's left edge
        var secondsPerPixel: Double
        var columns: Int
        var bottomSemitone: Double // low edge of the image's first row
        var rowsPerSemitone: Double
        var rows: Int
    }
    private(set) var stale: Picture?
    private var current: (key: [Double], picture: Picture)?
    /// Amplitude zoom of the last rendered image (for the state dump).
    var renderedGainDB: Double? { current?.key.last }
    /// Draws that showed the stretched previous image under a partial one.
    var staleDraws = 0

    /// Brings the cache up to date with the view; queues the missing columns. Returns the
    /// current picture (possibly partial) for drawing.
    func update(state: AppState) -> Picture? {
        guard let audio = state.audio, let px = state.pixelSeconds else { layout = nil; return nil }
        let fs = audio.sampleRate
        let p = Params(loadID: state.loadID, sampleRate: fs,
                       windowLength: SpectrogramConstants.windowLength(seconds: state.windowLengthMs / 1000, sampleRate: fs),
                       rowsPerSemitone: state.rowsPerSemitone, secondsPerPixel: px)
        if params.map({ !$0.sameScale(p) }) ?? true {
            reset(p, origin: state.viewStart, audio: audio)
        }
        var m = (state.viewStart - origin) / px
        if abs(m - m.rounded()) > 1e-3 {
            reset(p, origin: state.viewStart, audio: audio)
            m = 0
        }
        let first = Int(m.rounded())
        let n = state.timePixels
        let rows = Int((Double(state.mainCrossLength) * state.pixelScale).rounded())
        let firstRow = Int((state.freqBottom * p.rowsPerSemitone).rounded())
        layout = Layout(firstColumn: first, columns: n, firstRow: firstRow, rows: rows)
        // Keep one pane length on each side.
        columns = columns.filter { $0.key >= first - n && $0.key < first + 2 * n }
        queue = []
        complete = true
        for k in first..<(first + n) {
            guard let s = centreSample(k, audio: audio) else { continue }
            if columns[k] == nil {
                complete = false
                if !pending.contains(k) { queue.append((k, s)) }
            }
        }
        setBusy(running || !queue.isEmpty, state)
        startJobIfNeeded(state: state)
        return picture(state: state)
    }

    func centreSample(_ k: Int, audio: LoadedAudio) -> Int? {
        guard let p = params else { return nil }
        let s = roundSample((origin + (Double(k) + 0.5) * p.secondsPerPixel) * p.sampleRate)
        return s >= 0 && s < audio.frameCount ? s : nil
    }

    private func reset(_ p: Params, origin o: Double, audio: LoadedAudio) {
        let sameInput = params.map { $0.loadID == p.loadID && $0.sampleRate == p.sampleRate
            && $0.windowLength == p.windowLength && $0.rowsPerSemitone == p.rowsPerSemitone } ?? false
        if !sameInput || input == nil {
            let window = SpectrogramConstants.gaussian(p.windowLength)
            let rows = Int((SpectrogramConstants.rangeSemitones * p.rowsPerSemitone).rounded())
            let bins = (0..<rows).map { r in
                SpectrogramConstants.frequency(atSemitone: (Double(r) + 0.5) / p.rowsPerSemitone)
                    * Double(SpectrogramConstants.fftLength) / p.sampleRate
            }
            input = SpectrogramJobInput(mono: audio.mono, window: window, windowSum: window.reduce(0, +), binPositions: bins)
            totalRows = rows
        }
        params = p
        origin = o
        columns = [:]
        pending = []
        queue = []
        generation += 1
        current = nil
    }

    private func startJobIfNeeded(state: AppState) {
        guard !running, !queue.isEmpty, let input else { return }
        running = true
        setBusy(true, state)
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            while true {
                let next: [(k: Int, sample: Int)]? = await MainActor.run { self?.takeChunk(gen) }
                guard let next, !next.isEmpty else { break }
                let cols = computeSpectrogramColumns(input, centres: next.map(\.sample))
                let delay = await MainActor.run { SpectrogramConstants.testDelayMs }
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                await MainActor.run { self?.deliver(gen, keys: next.map(\.k), cols) }
            }
            await MainActor.run { self?.jobEnded() }
        }
    }

    /// Only on a change: setting an observed property while drawing would draw again.
    private func setBusy(_ on: Bool, _ state: AppState) {
        if state.spectrogramBusy != on { state.spectrogramBusy = on }
    }

    private func takeChunk(_ gen: Int) -> [(k: Int, sample: Int)]? {
        guard gen == generation else { return nil }
        let chunk = Array(queue.prefix(SpectrogramConstants.chunk))
        queue.removeFirst(chunk.count)
        pending.formUnion(chunk.map(\.k))
        return chunk
    }

    private func deliver(_ gen: Int, keys: [Int], _ cols: [[Float]]) {
        computedColumns += keys.count
        guard gen == generation else { return }
        for (k, c) in zip(keys, cols) { columns[k] = c; pending.remove(k) }
        AppState.shared.spectrogramVersion += 1
    }

    private func jobEnded() {
        running = false
        let state = AppState.shared
        setBusy(!queue.isEmpty, state)
        startJobIfNeeded(state: state)
        if !state.spectrogramBusy { state.spectrogramVersion += 1 }
    }

    // MARK: Rendering

    /// The visible columns as an image: `columns` wide, `rows` tall, data row 0 = the lowest
    /// row (so it lands at the bottom when drawn in a flipped view). Missing columns and rows
    /// outside the range are transparent. Cached while nothing changes.
    private func picture(state: AppState) -> Picture? {
        guard let layout, let p = params, layout.columns > 0, layout.rows > 0 else { return nil }
        let gain = state.amplitudeZoomDB
        let key: [Double] = [Double(generation), Double(state.spectrogramVersion), Double(layout.firstColumn),
                             Double(layout.columns), Double(layout.firstRow), Double(layout.rows), gain]
        if let c = current, c.key == key { return c.picture }
        let w = layout.columns, h = layout.rows
        var pixels = [UInt32](repeating: 0, count: w * h)
        let lut = magmaLUT
        let low = Float(SpectrogramConstants.displayLow), span = Float(SpectrogramConstants.displayHigh - SpectrogramConstants.displayLow)
        let g = Float(gain)
        pixels.withUnsafeMutableBufferPointer { px in
            for i in 0..<w {
                guard let col = columns[layout.firstColumn + i] else { continue }
                col.withUnsafeBufferPointer { c in
                    for q in 0..<h {
                        let r = layout.firstRow + q
                        guard r >= 0 && r < c.count else { continue }
                        let v = (c[r] + g - low) / span * 255
                        let idx = v.isNaN ? 0 : Int(min(max(v.rounded(), 0), 255))
                        px[q * w + i] = lut[idx]
                    }
                }
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                                           | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let pic = Picture(image: image, start: origin + Double(layout.firstColumn) * p.secondsPerPixel,
                          secondsPerPixel: p.secondsPerPixel, columns: w,
                          bottomSemitone: Double(layout.firstRow) / p.rowsPerSemitone,
                          rowsPerSemitone: p.rowsPerSemitone, rows: h)
        current = (key, pic)
        if complete { stale = pic }
        return pic
    }

    /// For the state dump's `specdump`: the visible levels (dB, before the amplitude zoom),
    /// column-major (columns × rows, rows low to high), NaN where nothing is drawn.
    func levelsDump(state: AppState) -> [String: Any] {
        guard let audio = state.audio, let layout, let p = params else { return ["available": false] }
        var levels = [Float](repeating: .nan, count: layout.columns * layout.rows)
        var centres: [Any] = []
        for i in 0..<layout.columns {
            let k = layout.firstColumn + i
            if let c = centreSample(k, audio: audio) { centres.append(c) } else { centres.append(NSNull()) }
            guard let col = columns[k] else { continue }
            for q in 0..<layout.rows {
                let r = layout.firstRow + q
                if r >= 0 && r < col.count { levels[i * layout.rows + q] = col[r] }
            }
        }
        let freqs: [Any] = (0..<layout.rows).map { q in
            let r = layout.firstRow + q
            return r >= 0 && r < totalRows ? SpectrogramConstants.frequency(atSemitone: (Double(r) + 0.5) / p.rowsPerSemitone) : NSNull()
        }
        let data = levels.withUnsafeBufferPointer { Data(buffer: $0) }
        return ["available": true, "complete": complete, "columns": layout.columns, "rows": layout.rows,
                "firstColumn": layout.firstColumn, "firstRow": layout.firstRow, "origin": origin,
                "secondsPerPixel": p.secondsPerPixel, "windowLength": p.windowLength, "sampleRate": p.sampleRate,
                "centreSamples": centres, "frequencies": freqs, "levelsFloat32LE": data.base64EncodedString()]
    }
}

/// Magma colour map (matplotlib), interpolated from 11 anchors, as RGBA bytes (big-endian order).
let magmaLUT: [UInt32] = {
    let anchors: [(Double, Double, Double)] = [
        (0x00, 0x00, 0x04), (0x14, 0x0e, 0x36), (0x3b, 0x0f, 0x70), (0x64, 0x1a, 0x80), (0x8c, 0x29, 0x81),
        (0xb7, 0x37, 0x79), (0xde, 0x49, 0x68), (0xf7, 0x70, 0x5c), (0xfe, 0x9f, 0x6d), (0xfe, 0xcf, 0x92),
        (0xfc, 0xfd, 0xbf),
    ]
    return (0..<256).map { i in
        let x = Double(i) / 255 * 10
        let a = min(Int(x), 9), t = x - Double(a)
        let (r0, g0, b0) = anchors[a], (r1, g1, b1) = anchors[a + 1]
        let r = UInt32((r0 + (r1 - r0) * t).rounded()), g = UInt32((g0 + (g1 - g0) * t).rounded())
        let b = UInt32((b0 + (b1 - b0) * t).rounded())
        return (r << 24 | g << 16 | b << 8 | 0xff).bigEndian
    }
}()
