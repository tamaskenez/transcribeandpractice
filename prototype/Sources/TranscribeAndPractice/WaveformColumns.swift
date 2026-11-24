import Accelerate

/// Per-block minimum, maximum and sum of squares of the mono mix (milestone 10), so a column
/// spanning many samples reads whole blocks instead of every sample.
struct WaveformSummary {
    static let blockSize = 256
    let blockMin: [Float]
    let blockMax: [Float]
    let blockSumSq: [Double]

    init(mono: [Float]) {
        let b = Self.blockSize
        let count = mono.count / b // whole blocks only; the tail is read from the samples
        var mins = [Float](repeating: 0, count: count)
        var maxs = [Float](repeating: 0, count: count)
        var sums = [Double](repeating: 0, count: count)
        mono.withUnsafeBufferPointer { x in
            for i in 0..<count {
                let p = x.baseAddress! + i * b
                var v: Float = 0
                vDSP_minv(p, 1, &v, vDSP_Length(b)); mins[i] = v
                vDSP_maxv(p, 1, &v, vDSP_Length(b)); maxs[i] = v
                vDSP_svesq(p, 1, &v, vDSP_Length(b)); sums[i] = Double(v)
            }
        }
        blockMin = mins; blockMax = maxs; blockSumSq = sums
    }
}

/// One waveform column: min, max and RMS of its value set (before the amplitude zoom).
struct WaveformColumn: Equatable {
    var index: Int
    var min: Float
    var max: Float
    var rms: Float
}

/// Columns of the mono signal over the visible range (see the spec, "Waveform display"): column
/// j of `count` covers sample positions (start + j·h)·fs … (start + (j+1)·h)·fs, h = (end −
/// start)/count, clipped to the file; its value set is the samples strictly inside plus the
/// interpolated signal at both (clipped) edges. Columns entirely outside the file are left out.
func waveformColumns(mono: [Float], summary: WaveformSummary, sampleRate fs: Double,
                     start: Double, end: Double, count: Int) -> [WaveformColumn] {
    let frames = mono.count
    guard frames > 0, count > 0, end > start else { return [] }
    let h = (end - start) / Double(count)
    let last = Double(frames - 1)
    let bs = WaveformSummary.blockSize
    var result: [WaveformColumn] = []
    result.reserveCapacity(count)
    mono.withUnsafeBufferPointer { x in
        let base = x.baseAddress!
        func interp(_ p: Double) -> Float {
            let i0 = Int(p)
            let i1 = Swift.min(i0 + 1, frames - 1)
            let f = Float(p - Double(i0))
            return base[i0] * (1 - f) + base[i1] * f
        }
        // Min, max, sum of squares and count of samples lo..<hi.
        func raw(_ lo: Int, _ hi: Int) -> (Float, Float, Double, Int) {
            guard hi > lo else { return (.infinity, -.infinity, 0, 0) }
            var mn: Float = 0, mx: Float = 0, sq: Float = 0
            let n = vDSP_Length(hi - lo)
            vDSP_minv(base + lo, 1, &mn, n)
            vDSP_maxv(base + lo, 1, &mx, n)
            vDSP_svesq(base + lo, 1, &sq, n)
            return (mn, mx, Double(sq), hi - lo)
        }
        func blocks(_ lo: Int, _ hi: Int) -> (Float, Float, Double, Int) {
            guard hi > lo else { return (.infinity, -.infinity, 0, 0) }
            let n = vDSP_Length(hi - lo)
            var mn: Float = 0, mx: Float = 0, sq: Double = 0
            summary.blockMin.withUnsafeBufferPointer { vDSP_minv($0.baseAddress! + lo, 1, &mn, n) }
            summary.blockMax.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + lo, 1, &mx, n) }
            summary.blockSumSq.withUnsafeBufferPointer { vDSP_sveD($0.baseAddress! + lo, 1, &sq, n) }
            return (mn, mx, sq, (hi - lo) * bs)
        }
        for j in 0..<count {
            let p0 = (start + Double(j) * h) * fs
            let p1 = (start + Double(j + 1) * h) * fs
            let a = Swift.max(p0, 0), b = Swift.min(p1, last)
            guard a <= b else { continue }
            let ea = interp(a), eb = interp(b)
            var mn = Swift.min(ea, eb), mx = Swift.max(ea, eb)
            var sq = Double(ea) * Double(ea) + Double(eb) * Double(eb)
            var n = 2
            // Samples strictly inside the slice: kLo ... kHi.
            let kLo = Int(a.rounded(.down)) + 1, kEnd = Int(b.rounded(.up)) // exclusive
            if kEnd > kLo {
                let firstBlock = (kLo + bs - 1) / bs
                let endBlock = Swift.min(kEnd / bs, summary.blockMin.count)
                let parts = firstBlock < endBlock
                    ? [raw(kLo, firstBlock * bs), blocks(firstBlock, endBlock), raw(endBlock * bs, kEnd)]
                    : [raw(kLo, kEnd)]
                for (pmn, pmx, psq, pn) in parts where pn > 0 {
                    mn = Swift.min(mn, pmn); mx = Swift.max(mx, pmx); sq += psq; n += pn
                }
            }
            result.append(WaveformColumn(index: j, min: mn, max: mx, rms: Float((sq / Double(n)).squareRoot())))
        }
    }
    return result
}
