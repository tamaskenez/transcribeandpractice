import AppKit
import SwiftUI

/// Spectrum pane next to the spectrogram (milestone 9, experimental): the spectrogram's level
/// column at the playhead, with a piano-key outline overlaid. Its frequency axis is the
/// spectrogram's (same rows, same frequency pan).
enum SpectrumConstants {
    /// Pane thickness along the amplitude axis (points).
    static let thickness: CGFloat = 120
    /// Black key length as a fraction of the white key length (real piano ≈ 95 / 150 mm).
    static let blackKeyFraction: CGFloat = 0.63
}

/// The level column (dB, before the amplitude zoom) at a sample, computed like a spectrogram
/// column. Caches the last result.
@MainActor
final class SpectrumEngine {
    private struct InputKey: Equatable { var loadID: Int; var sampleRate: Double; var windowLength: Int; var rowsPerSemitone: Double }
    private var inputKey: InputKey?
    private var input: SpectrogramJobInput?
    private var last: (key: InputKey, sample: Int, levels: [Float])?

    /// Levels of all rows of the frequency range (low to high) at the playhead.
    func levels(state: AppState) -> [Float]? {
        guard let audio = state.audio else { return nil }
        let fs = audio.sampleRate
        let key = InputKey(loadID: state.loadID, sampleRate: fs,
                           windowLength: SpectrogramConstants.windowLength(seconds: state.windowLengthMs / 1000, sampleRate: fs),
                           rowsPerSemitone: state.rowsPerSemitone)
        let sample = min(max(roundSample(state.playhead * fs), 0), max(audio.frameCount - 1, 0))
        if let last, last.key == key, last.sample == sample { return last.levels }
        if inputKey != key || input == nil {
            let window = SpectrogramConstants.gaussian(key.windowLength)
            let rows = Int((SpectrogramConstants.rangeSemitones * key.rowsPerSemitone).rounded())
            let bins = (0..<rows).map { r in
                SpectrogramConstants.frequency(atSemitone: (Double(r) + 0.5) / key.rowsPerSemitone)
                    * Double(SpectrogramConstants.fftLength) / fs
            }
            input = SpectrogramJobInput(mono: audio.mono, window: window, windowSum: window.reduce(0, +), binPositions: bins)
            inputKey = key
        }
        guard let input, let col = computeSpectrogramColumns(input, centres: [sample]).first else { return nil }
        last = (key, sample, col)
        return col
    }
}

final class SpectrumNSView: NSView {
    var state: AppState?
    override var isFlipped: Bool { true }

    private var orientation: TimeOrientation { state?.orientation ?? .horizontal }
    /// Along the frequency axis / along the amplitude (key length) axis.
    private var crossLength: CGFloat { orientation == .horizontal ? bounds.height : bounds.width }
    private var depth: CGFloat { orientation == .horizontal ? bounds.width : bounds.height }

    /// View rect from a frequency span (points from the pane's low edge) and a key-length span
    /// (points from the keys' back end: the left edge (horizontal) or the top edge (vertical)).
    private func rect(freq f0: CGFloat, _ f1: CGFloat, depth d0: CGFloat, _ d1: CGFloat) -> NSRect {
        orientation == .horizontal
            ? NSRect(x: d0, y: crossLength - f1, width: d1 - d0, height: f1 - f0)
            : NSRect(x: f0, y: d0, width: f1 - f0, height: d1 - d0)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let state, state.audio != nil else { return }
        drawSpectrum(state)
        drawKeys(state)
    }

    private func drawSpectrum(_ state: AppState) {
        guard let levels = state.spectrum.levels(state: state) else { return }
        let rps = state.rowsPerSemitone
        let firstRow = Int((state.freqBottom * rps).rounded())
        let rows = Int(crossLength.rounded())
        let pps = CGFloat(SpectrogramConstants.pointsPerSemitone / rps)
        let low = SpectrogramConstants.displayLow, span = SpectrogramConstants.displayHigh - low
        let gain = state.amplitudeZoomDB
        let horizontal = orientation == .horizontal
        let len = depth
        // Amplitude grows rightwards from the left edge (horizontal) or upwards from the bottom (vertical).
        func point(_ f: CGFloat, _ a: CGFloat) -> CGPoint {
            horizontal ? CGPoint(x: a * len, y: crossLength - f) : CGPoint(x: f, y: len - a * len)
        }
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for q in 0..<max(rows, 0) {
            let r = firstRow + q
            guard r >= 0 && r < levels.count else {
                if !current.isEmpty { segments.append(current); current = [] }
                continue
            }
            let a = CGFloat(min(max((Double(levels[r]) + gain - low) / span, 0), 1))
            current.append(point((CGFloat(q) + 0.5) * pps, a))
        }
        if !current.isEmpty { segments.append(current) }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).setClip()
        for seg in segments {
            guard let first = seg.first, let lastPoint = seg.last else { continue }
            let line = NSBezierPath()
            line.move(to: first)
            for p in seg.dropFirst() { line.line(to: p) }
            let fill = line.copy() as! NSBezierPath
            fill.line(to: point(horizontal ? crossLength - lastPoint.y : lastPoint.x, 0))
            fill.line(to: point(horizontal ? crossLength - first.y : first.x, 0))
            fill.close()
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            fill.fill()
            NSColor.controlAccentColor.setStroke()
            line.lineWidth = 1
            line.stroke()
        }
    }

    /// Piano-key outlines over the whole frequency range: each key spans its semitone on the
    /// frequency axis; black keys run from the back end for `blackKeyFraction` of the length;
    /// white keys run the full length, their boundaries at the semitone edge (E|F, B|C) or, past
    /// the black keys, at the middle of the black key between them.
    private func drawKeys(_ state: AppState) {
        let pps = CGFloat(SpectrogramConstants.pointsPerSemitone)
        let bottom = state.freqBottom
        let len = depth
        let blackLen = (len * SpectrumConstants.blackKeyFraction).rounded()
        func pos(_ note: Int) -> CGFloat { (CGFloat(Double(note - SpectrogramConstants.lowestNote) - bottom) * pps).rounded() }
        func isBlack(_ note: Int) -> Bool { [1, 3, 6, 8, 10].contains(note % 12) }
        NSColor.labelColor.withAlphaComponent(0.45).setFill()
        let w: CGFloat = 1
        // A boundary line across the keys at frequency position f, from depth d0 to d1.
        func across(_ f: CGFloat, _ d0: CGFloat, _ d1: CGFloat) { rect(freq: f - w / 2, f + w / 2, depth: d0, d1).fill() }
        // A line along the keys at depth d, over a frequency span.
        func along(_ d: CGFloat, _ f0: CGFloat, _ f1: CGFloat) { rect(freq: f0 - w / 2, f1 + w / 2, depth: d - w / 2, d + w / 2).fill() }
        let lo = SpectrogramConstants.lowestNote, hi = SpectrogramConstants.highestNote
        let rangeLow = pos(lo), rangeHigh = pos(hi + 1)
        // Bounding box: the range's edges and the back and front ends (inset half a line).
        across(rangeLow + w / 2, 0, len)
        across(rangeHigh - w / 2, 0, len)
        along(w / 2, rangeLow, rangeHigh)
        along(len - w / 2, rangeLow, rangeHigh)
        for note in lo...hi {
            let f0 = pos(note), f1 = pos(note + 1)
            if f1 < 0 || f0 > crossLength { continue }
            if isBlack(note) {
                across(f0, 0, blackLen)
                across(f1, 0, blackLen)
                along(blackLen, f0, f1)
                // The white keys' boundary past the black key: its middle.
                across(((f0 + f1) / 2).rounded(), blackLen, len)
            } else if note < hi, !isBlack(note + 1) {
                across(f1, 0, len)
            }
        }
    }
}

struct SpectrumView: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> SpectrumNSView { SpectrumNSView() }

    func updateNSView(_ view: SpectrumNSView, context: Context) {
        view.state = state
        _ = (state.audio?.mono.count, state.orientation, state.playhead, state.amplitudeZoomDB, state.windowLengthMs,
             state.freqLow, state.mainCrossLength, state.loadID)
        view.needsDisplay = true
    }
}
