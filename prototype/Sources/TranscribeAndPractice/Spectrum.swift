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
    /// The sample the last column was computed at.
    var lastSample: Int? { last?.sample }

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

    // The pane lies over the main pane: presses don't reach it.
    override func mouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var orientation: TimeOrientation { state?.orientation ?? .horizontal }
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let state, state.audio != nil else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).setClip()
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

    /// A key outline line as drawn: `freq` is the span along the frequency axis (points from the
    /// pane's low edge), `depth` along the keys (points from the back end); `rect` in view
    /// coordinates.
    struct KeyLine {
        var kind: String
        var freq: ClosedRange<CGFloat>
        var depth: ClosedRange<CGFloat>
        var rect: NSRect
    }

    /// Piano-key outlines over the whole frequency range: each key spans its semitone on the
    /// frequency axis; black keys run from the back end for `blackKeyFraction` of the length;
    /// white keys run the full length, their boundaries at the semitone edge (E|F, B|C) or, past
    /// the black keys, at the middle of the black key between them. Lines entirely outside the
    /// pane are left out (the rest is clipped when drawn).
    func keyLines() -> [KeyLine] {
        guard let state else { return [] }
        let pps = CGFloat(SpectrogramConstants.pointsPerSemitone)
        let bottom = state.freqBottom
        let len = depth
        let blackLen = (len * SpectrumConstants.blackKeyFraction).rounded()
        func pos(_ note: Int) -> CGFloat { (CGFloat(Double(note - SpectrogramConstants.lowestNote) - bottom) * pps).rounded() }
        func isBlack(_ note: Int) -> Bool { [1, 3, 6, 8, 10].contains(note % 12) }
        let w: CGFloat = 1
        var lines: [KeyLine] = []
        func add(_ kind: String, _ f0: CGFloat, _ f1: CGFloat, _ d0: CGFloat, _ d1: CGFloat) {
            guard f1 > 0, f0 < crossLength else { return }
            lines.append(KeyLine(kind: kind, freq: f0...f1, depth: d0...d1, rect: rect(freq: f0, f1, depth: d0, d1)))
        }
        // A boundary line across the keys at frequency position f, from depth d0 to d1.
        func across(_ kind: String, _ f: CGFloat, _ d0: CGFloat, _ d1: CGFloat) { add(kind, f - w / 2, f + w / 2, d0, d1) }
        // A line along the keys at depth d, over a frequency span.
        func along(_ kind: String, _ d: CGFloat, _ f0: CGFloat, _ f1: CGFloat) { add(kind, f0 - w / 2, f1 + w / 2, d - w / 2, d + w / 2) }
        let lo = SpectrogramConstants.lowestNote, hi = SpectrogramConstants.highestNote
        let rangeLow = pos(lo), rangeHigh = pos(hi + 1)
        // Bounding box: the range's edges and the back and front ends (inset half a line).
        across("rangeLow", rangeLow + w / 2, 0, len)
        across("rangeHigh", rangeHigh - w / 2, 0, len)
        along("backEnd", w / 2, rangeLow, rangeHigh)
        along("frontEnd", len - w / 2, rangeLow, rangeHigh)
        for note in lo...hi {
            let f0 = pos(note), f1 = pos(note + 1)
            if f1 < 0 || f0 > crossLength { continue }
            if isBlack(note) {
                across("blackSide", f0, 0, blackLen)
                across("blackSide", f1, 0, blackLen)
                along("blackEnd", blackLen, f0, f1)
                // The white keys' boundary past the black key: its middle.
                across("whiteBoundaryMiddle", ((f0 + f1) / 2).rounded(), blackLen, len)
            } else if note < hi, !isBlack(note + 1) {
                across("whiteBoundaryEdge", f1, 0, len)
            }
        }
        return lines
    }

    private func drawKeys(_ state: AppState) {
        NSColor.labelColor.withAlphaComponent(0.45).setFill()
        for line in keyLines() { line.rect.fill() }
    }

    /// The visible part of the column: centre sample, first row, and the levels (dB, before the
    /// amplitude zoom) of the pane's rows, low to high (nil outside the range). For the dump.
    func columnDump() -> (centre: Int, firstRow: Int, levels: [Float?])? {
        guard let state, let levels = state.spectrum.levels(state: state), let c = state.spectrum.lastSample else { return nil }
        let firstRow = Int((state.freqBottom * state.rowsPerSemitone).rounded())
        let rows = Int(crossLength.rounded())
        return (c, firstRow, (0..<max(rows, 0)).map { q in
            let r = firstRow + q
            return r >= 0 && r < levels.count ? levels[r] : nil
        })
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
