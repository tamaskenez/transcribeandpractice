import AppKit
import SwiftUI

/// Waveform pane (navigator or main). Handles zoom, pan and selection input; all of it acts on
/// the shared visible range and selection in AppState.
final class WaveformNSView: NSView {
    /// Pane name, for the state dump.
    var name = ""
    var state: AppState?
    var background: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
    /// The navigator's time-marker strip instead of a waveform: draws ticks and labels; a plain
    /// press sets the playhead (or jumps playback) and never touches the selection.
    var isRuler = false

    private enum Drag {
        case select(anchor: Double, extend: Bool)
        /// Option/middle drag: the grabbed time (and, in the spectrogram, the grabbed frequency
        /// position in semitones) follows the pointer.
        case pan(grabbedTime: Double, grabbedSemitone: Double?)
        /// Moving the grabbed lines (a selection edge, the playhead, the last start) together:
        /// `anchor` is the other selection edge if an edge is grabbed; `offset` = line time −
        /// press time.
        case lines(Grab, anchor: Double?, offset: Double)
        /// Moving the whole selection.
        case move(original: ClosedRange<Double>, pressTime: Double)
        /// Ruler: a plain press. Stopped at the press: the playhead follows the pointer; playing:
        /// playback jumped to the press point and the rest of the drag does nothing.
        case seek(playing: Bool)
        /// Ruler: a beat mark (`sample` at the press); `placedIndex` is set once it moves (a
        /// computed beat becomes placed then). `offset` = beat time − press time.
        case beat(sample: Int, placedIndex: Int?, offset: Double)
    }

    /// Lines grabbed by a press: the nearest one within the tolerance, plus the other lines at
    /// the same time (within one sample). At most one selection edge.
    struct Grab: Equatable {
        var startEdge = false, endEdge = false, playhead = false, lastStart = false
        var time: Double = 0
        var edge: Bool { startEdge || endEdge }
    }
    /// What a plain press at a point would do; also decides the cursor.
    private enum Hover: Equatable { case none, lines(Grab), inside, beat(sample: Int) }
    /// Distance (points) from a line within which it can be grabbed.
    private static let edgeTolerance: CGFloat = 4
    /// Name of the cursor the view last set, for the state dump.
    private(set) var cursorName = "arrow"
    private var drag: Drag?
    private var pressPoint: CGPoint = .zero
    private var dragged = false

    override var isFlipped: Bool { true }

    var orientation: TimeOrientation { state?.orientation ?? .horizontal }
    private var timeLength: CGFloat { orientation == .horizontal ? bounds.width : bounds.height }

    private struct ColumnsKey: Equatable { var loadID: Int; var start: Double; var end: Double; var count: Int }
    private var columnsCache: (key: ColumnsKey, columns: [WaveformColumn])?
    /// Column computations since launch and the time the last one took (ms), for the dump.
    private(set) var columnComputations = 0
    private(set) var lastColumnsMs: Double?

    /// The waveform columns of the visible range (cached by file, range and column count).
    func columns() -> [WaveformColumn] {
        guard let state, let audio = state.audio else { return [] }
        let key = ColumnsKey(loadID: state.loadID, start: state.viewStart, end: state.viewEnd,
                             count: Int(timeLength.rounded(.down)))
        if let columnsCache, columnsCache.key == key { return columnsCache.columns }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let cols = waveformColumns(mono: audio.mono, summary: audio.summary, sampleRate: audio.sampleRate,
                                   start: key.start, end: key.end, count: key.count)
        lastColumnsMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        columnComputations += 1
        columnsCache = (key, cols)
        return cols
    }

    /// A drawn column: the min/max and RMS bars across the time axis (pane coordinates, after
    /// the amplitude zoom and the clipping; nil when nothing of it is in the pane) and its span
    /// along the time axis.
    struct ColumnBars {
        var column: WaveformColumn
        var axis: ClosedRange<CGFloat>
        var bar: ClosedRange<CGFloat>?
        var rmsBar: ClosedRange<CGFloat>?
    }

    func columnBars() -> [ColumnBars] {
        guard let state else { return [] }
        let cols = columns()
        let count = Int(timeLength.rounded(.down))
        guard count > 0 else { return [] }
        let step = timeLength / CGFloat(count)
        let cross = crossLength
        let gain = state.amplitudeGain
        let horizontal = orientation == .horizontal
        // Zoomed in to 1 ms per column or closer: no RMS marks.
        let showRMS = state.viewLength / Double(count) > Self.rmsHideSecondsPerColumn
        // Cross position of a value: positive up (horizontal) or right (vertical).
        func pos(_ v: Float) -> CGFloat {
            let g = CGFloat(Double(v) * gain)
            return horizontal ? cross / 2 * (1 - g) : cross / 2 * (1 + g)
        }
        func clip(_ lo: CGFloat, _ hi: CGFloat) -> ClosedRange<CGFloat>? {
            let a = max(lo, 0), b = min(hi, cross)
            return b > a ? a...b : nil
        }
        return cols.map { c in
            var lo = min(pos(c.min), pos(c.max)), hi = max(pos(c.min), pos(c.max))
            if hi - lo < 1 { let m = (lo + hi) / 2; lo = m - 0.5; hi = m + 0.5 }
            let r0 = min(pos(-c.rms), pos(c.rms)), r1 = max(pos(-c.rms), pos(c.rms))
            return ColumnBars(column: c, axis: CGFloat(c.index) * step...CGFloat(c.index + 1) * step,
                              bar: clip(lo, hi), rmsBar: showRMS ? clip(r0, r1) : nil)
        }
    }

    /// At this many seconds per column or fewer the RMS marks are not drawn.
    static let rmsHideSecondsPerColumn = 0.001

    /// Lighter tint of the accent color for the RMS bars.
    static var rmsColor: NSColor { NSColor.controlAccentColor.blended(withFraction: 0.5, of: .white) ?? .controlAccentColor }

    /// Position along the time axis (points from the pane's start) of a point in view coordinates.
    private func axisPosition(_ p: CGPoint) -> CGFloat { orientation == .horizontal ? p.x : p.y }

    private func time(atAxis pos: CGFloat) -> Double {
        guard let state, timeLength > 0 else { return 0 }
        return state.viewStart + Double(pos / timeLength) * state.viewLength
    }

    private func axis(ofTime t: Double) -> CGFloat {
        guard let state, state.viewLength > 0 else { return 0 }
        return CGFloat((t - state.viewStart) / state.viewLength) * timeLength
    }

    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    // MARK: Drawing

    /// The main pane in spectrogram mode.
    var isSpectrogram: Bool { name == "main" && state?.mainMode == .spectrogram }
    private var crossLength: CGFloat { orientation == .horizontal ? bounds.height : bounds.width }
    /// Distance (points) from the pane's low-frequency edge: the bottom (horizontal) or left (vertical).
    private func crossFromLow(_ p: CGPoint) -> CGFloat { orientation == .horizontal ? bounds.height - p.y : p.x }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportSize()
    }

    /// The main pane's size, for the pixel grid of panning and the spectrogram.
    func reportSize() {
        guard name == "main", let state else { return }
        let a = timeLength, c = crossLength
        if state.mainAxisLength != a { state.mainAxisLength = a }
        if state.mainCrossLength != c { state.mainCrossLength = c }
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        let horizontal = orientation == .horizontal
        if isSpectrogram {
            drawSpectrogram()
            drawEditorLines()
            drawSelection()
            drawLines()
            return
        }
        if !isRuler { drawSelection() }
        if isRuler {
            drawRuler()
            drawLines()
            return
        }

        let zero = NSBezierPath()
        if horizontal {
            zero.move(to: CGPoint(x: 0, y: bounds.midY)); zero.line(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        } else {
            zero.move(to: CGPoint(x: bounds.midX, y: 0)); zero.line(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        }
        NSColor.separatorColor.setStroke()
        zero.lineWidth = 1
        zero.stroke()

        defer { drawLines() }
        let bars = columnBars()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).setClip()
        func rect(_ axis: ClosedRange<CGFloat>, _ across: ClosedRange<CGFloat>) -> NSRect {
            horizontal
                ? NSRect(x: axis.lowerBound, y: across.lowerBound, width: axis.upperBound - axis.lowerBound, height: across.upperBound - across.lowerBound)
                : NSRect(x: across.lowerBound, y: axis.lowerBound, width: across.upperBound - across.lowerBound, height: axis.upperBound - axis.lowerBound)
        }
        let minMax = NSBezierPath(), rms = NSBezierPath()
        for b in bars {
            if let bar = b.bar { minMax.appendRect(rect(b.axis, bar)) }
            // RMS: only the two endpoints (±rms), 1 point thick, so the bar doesn't hide the waveform.
            if let r = b.rmsBar {
                for e in [r.lowerBound, r.upperBound] where e > 0 && e < crossLength {
                    rms.appendRect(rect(b.axis, max(e - 0.5, 0)...min(e + 0.5, crossLength)))
                }
            }
        }
        NSColor.controlAccentColor.setFill()
        minMax.fill()
        Self.rmsColor.setFill()
        rms.fill()
        drawEditorLines()
        if name == "navigator", state?.mainMode == .spectrogram { drawAnalysisWindow() }
    }

    /// Navigator in spectrogram mode: the spectrogram's window function centred at the playhead,
    /// mirrored like the waveform, its peak touching the pane's edges (milestone 9). Two
    /// polylines (+w, −w), each starting and ending on the zero line; nil when not shown.
    func analysisWindowPolylines() -> [[CGPoint]]? {
        guard name == "navigator", let state, state.mainMode == .spectrogram, let audio = state.audio,
              timeLength > 0, state.viewLength > 0 else { return nil }
        let fs = audio.sampleRate
        let n = SpectrogramConstants.windowLength(seconds: state.windowLengthMs / 1000, sampleRate: fs)
        let half = Double(n - 1) / 2 / fs
        let centre = Double(roundSample(state.playhead * fs)) / fs
        let a0 = axis(ofTime: centre - half), a1 = axis(ofTime: centre + half)
        guard a1 > 0, a0 < timeLength else { return [] }
        let steps = 2 * max(Int(((a1 - a0) / 2).rounded(.up)), 32) // even: the peak is a sample
        let cross = crossLength
        func point(_ a: CGFloat, _ v: Double) -> CGPoint {
            orientation == .horizontal ? CGPoint(x: a, y: cross / 2 * (1 - CGFloat(v))) : CGPoint(x: cross / 2 * (1 + CGFloat(v)), y: a)
        }
        let samples: [(CGFloat, Double)] = (0...steps).map { i in
            let u = Double(i) / Double(steps)
            let x = SpectrogramConstants.alpha * (2 * u - 1)
            return (a0 + CGFloat(u) * (a1 - a0), exp(-0.5 * x * x))
        }
        return [1.0, -1.0].map { sign in
            [point(a0, 0)] + samples.map { point($0.0, sign * $0.1) } + [point(a1, 0)]
        }
    }

    private func drawAnalysisWindow() {
        guard let lines = analysisWindowPolylines() else { return }
        for pts in lines {
            guard let first = pts.first else { continue }
            let path = NSBezierPath()
            path.move(to: first)
            for p in pts.dropFirst() { path.line(to: p) }
            NSColor.systemOrange.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    /// The spectrogram image: while columns are missing, the last complete image stretched to
    /// the current mapping, under the current (partial) one. The image is laid out with time
    /// along u and high frequencies at the top (v = 0); vertical mode rotates it.
    private func drawSpectrogram() {
        guard let state, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let engine = state.spectrogram
        let picture = engine.update(state: state)
        let cross = crossLength
        let bottom = state.freqBottom
        let pps = CGFloat(SpectrogramConstants.pointsPerSemitone)
        func rect(_ p: SpectrogramEngine.Picture) -> CGRect {
            let u0 = axis(ofTime: p.start), u1 = axis(ofTime: p.start + Double(p.columns) * p.secondsPerPixel)
            let top = p.bottomSemitone + Double(p.rows) / p.rowsPerSemitone
            let v0 = cross - CGFloat(top - bottom) * pps, v1 = cross - CGFloat(p.bottomSemitone - bottom) * pps
            return CGRect(x: u0, y: v0, width: u1 - u0, height: v1 - v0)
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds)
        if orientation == .vertical { ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: cross, ty: 0)) }
        ctx.interpolationQuality = .none
        // In the flipped view the image's first data row (the lowest frequency) lands at the bottom.
        if !engine.complete, let stale = engine.stale {
            ctx.draw(stale.image, in: rect(stale))
            engine.staleDraws += 1
        }
        if let picture { ctx.draw(picture.image, in: rect(picture)) }
    }

    private func drawSelection() {
        guard let sel = state?.selection else { return }
        let a = max(axis(ofTime: sel.lowerBound), 0), b = min(axis(ofTime: sel.upperBound), timeLength)
        guard b > a else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        (orientation == .horizontal ? NSRect(x: a, y: 0, width: b - a, height: bounds.height)
                                    : NSRect(x: 0, y: a, width: bounds.width, height: b - a)).fill()
    }

    // MARK: Ruler

    struct Tick {
        var time: Double
        var axis: CGFloat
        var major: Bool
        var label: String?
        /// Label frame in view coordinates; nil for minor ticks and labels that don't fit.
        var labelFrame: CGRect?
    }

    /// Ticks of the visible range (within the file), as drawn.
    func rulerTicks() -> [Tick] {
        guard let state, state.audio != nil, !showsBeats, timeLength > 0, state.viewLength > 0 else { return [] }
        let horizontal = orientation == .horizontal
        let pointsPerSecond = Double(timeLength) / state.viewLength
        let lo = max(state.viewStart, 0), hi = min(state.viewEnd, state.duration)
        guard hi >= lo else { return [] }
        // The smallest step whose labels keep `rulerLabelGap` apart.
        var step = rulerSteps.last!
        for candidate in rulerSteps {
            let size = rulerLabelSize(formatRulerTime(hi, step: candidate))
            let extent = horizontal ? rulerLabelOffset + size.width : rulerLabelOffset + size.height
            if candidate * pointsPerSecond >= Double(extent + rulerLabelGap) { step = candidate; break }
        }
        var ticks: [Tick] = []
        let first = Int((lo / step - 1e-9).rounded(.up)), last = Int((hi / step + 1e-9).rounded(.down))
        if last >= first {
            for k in first...last {
                let t = Double(k) * step
                let a = axis(ofTime: t)
                let label = formatRulerTime(t, step: step)
                let size = rulerLabelSize(label)
                let frame = horizontal
                    ? CGRect(x: a + rulerLabelOffset, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
                    : CGRect(x: rulerLabelOffset, y: a + rulerLabelOffset, width: size.width, height: size.height)
                ticks.append(Tick(time: t, axis: a, major: true, label: label,
                                  labelFrame: bounds.contains(frame) ? frame : nil))
            }
        }
        let parts = rulerMinorParts(step)
        let minor = step / Double(parts)
        if minor * pointsPerSecond >= Double(rulerMinMinorSpacing) {
            let mFirst = Int((lo / minor - 1e-9).rounded(.up)), mLast = Int((hi / minor + 1e-9).rounded(.down))
            if mLast >= mFirst {
                for m in mFirst...mLast where m % parts != 0 {
                    let t = Double(m) * minor
                    ticks.append(Tick(time: t, axis: axis(ofTime: t), major: false))
                }
            }
        }
        return ticks
    }

    /// A beat as drawn in the strip (beats mode).
    struct BeatMark {
        enum Kind: String { case big, bigDotted, small, dot }
        var time: Double
        var axis: CGFloat
        var kind: Kind
        /// Bar number shown as the label (numbered downbeats only).
        var bar: Int?
        var labelFrame: CGRect?
        var sample = 0
    }

    /// Whether the strip draws beats (otherwise time ticks).
    var showsBeats: Bool { isRuler && state?.stripShowsBeats == true }

    /// Beat marks of the visible range, as drawn (see the spec's crowding rules).
    func beatMarks() -> [BeatMark] {
        guard let state, let audio = state.audio, !state.beats.isEmpty, timeLength > 0, state.viewLength > 0
        else { return [] }
        let horizontal = orientation == .horizontal
        // Bar numbers over the whole file; then the visible beats.
        var bars: [Int?] = []
        var bar = 0
        for b in state.beats { if b.isDownbeat { bar += 1; bars.append(bar) } else { bars.append(nil) } }
        let lo = max(state.viewStart, 0), hi = min(state.viewEnd, state.duration)
        let visible = state.beats.indices.filter {
            let t = Double(state.beats[$0].sample) / audio.sampleRate
            return t >= lo && t <= hi
        }
        func t(_ i: Int) -> Double { Double(state.beats[i].sample) / audio.sampleRate }
        func extent(_ n: Int) -> CGFloat {
            let size = rulerLabelSize(String(n))
            return rulerLabelOffset + (horizontal ? size.width : size.height)
        }
        // Bar number step: the smallest power of two keeping the labels apart.
        let downbeats = visible.filter { bars[$0] != nil }
        var k = 1
        while k < max(bar, 1) {
            let numbered = downbeats.filter { (bars[$0]! - 1) % k == 0 }
            let fits = zip(numbered, numbered.dropFirst()).allSatisfy { a, b in
                axis(ofTime: t(b)) - axis(ofTime: t(a)) >= extent(bars[a]!) + rulerLabelGap
            }
            if fits { break }
            k *= 2
        }
        let isNumbered = { (i: Int) in bars[i].map { ($0 - 1) % k == 0 } ?? false }
        // Small marks: all beats, or only the un-numbered downbeats, or none.
        func spaced(_ idx: [Int]) -> Bool {
            zip(idx, idx.dropFirst()).allSatisfy { axis(ofTime: t($1)) - axis(ofTime: t($0)) >= rulerMinMinorSpacing }
        }
        let smallAll = spaced(visible)
        let unnumberedDown = downbeats.filter { !isNumbered($0) }
        let smallDown = !smallAll && spaced(unnumberedDown)
        var marks: [BeatMark] = []
        for i in visible {
            let beat = state.beats[i]
            let a = axis(ofTime: t(i))
            if isNumbered(i) {
                let n = bars[i]!
                let size = rulerLabelSize(String(n))
                let frame = horizontal
                    ? CGRect(x: a + rulerLabelOffset, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
                    : CGRect(x: rulerLabelOffset, y: a + rulerLabelOffset, width: size.width, height: size.height)
                marks.append(BeatMark(time: t(i), axis: a, kind: beat.firstBeat == .computed ? .bigDotted : .big,
                                      bar: n, labelFrame: bounds.contains(frame) ? frame : nil, sample: beat.sample))
            } else if smallAll || (smallDown && beat.isDownbeat) {
                marks.append(BeatMark(time: t(i), axis: a, kind: beat.source == .computed ? .dot : .small, sample: beat.sample))
            }
        }
        return marks
    }

    private func drawBeats() {
        let horizontal = orientation == .horizontal
        let w = bounds.width, h = bounds.height
        for mark in beatMarks() {
            let a = mark.axis
            switch mark.kind {
            case .big:
                NSColor.secondaryLabelColor.setFill()
                (horizontal ? NSRect(x: a - 0.5, y: 0, width: 1, height: h) : NSRect(x: 0, y: a - 0.5, width: w, height: 1)).fill()
            case .bigDotted:
                NSColor.secondaryLabelColor.setFill()
                var p: CGFloat = 0
                let len = horizontal ? h : w
                while p < len {
                    let d = min(rulerDash, len - p)
                    (horizontal ? NSRect(x: a - 0.5, y: h - p - d, width: 1, height: d)
                                : NSRect(x: w - p - d, y: a - 0.5, width: d, height: 1)).fill()
                    p += 2 * rulerDash
                }
            case .small:
                NSColor.tertiaryLabelColor.setFill()
                (horizontal ? NSRect(x: a - 0.5, y: h - rulerMinorLength, width: 1, height: rulerMinorLength)
                            : NSRect(x: w - rulerMinorLength, y: a - 0.5, width: rulerMinorLength, height: 1)).fill()
            case .dot:
                NSColor.tertiaryLabelColor.setFill()
                let c = horizontal ? CGPoint(x: a, y: h - rulerMinorLength / 2) : CGPoint(x: w - rulerMinorLength / 2, y: a)
                NSBezierPath(ovalIn: NSRect(x: c.x - rulerDotDiameter / 2, y: c.y - rulerDotDiameter / 2,
                                            width: rulerDotDiameter, height: rulerDotDiameter)).fill()
            }
            if let n = mark.bar, let frame = mark.labelFrame {
                NSAttributedString(string: String(n), attributes: rulerLabelAttributes).draw(at: frame.origin)
            }
        }
    }

    /// Axis position of the pointer line in the strip, if drawn.
    var pointerAxis: CGFloat? {
        guard isRuler, let state, state.audio != nil, let t = state.pointerTime else { return nil }
        let a = axis(ofTime: t)
        return a >= 0 && a <= timeLength ? a : nil
    }

    private func drawPointerLine() {
        guard let a = pointerAxis else { return }
        NSColor.secondaryLabelColor.setFill()
        (orientation == .horizontal ? NSRect(x: a - 0.5, y: 0, width: 1, height: bounds.height)
                                    : NSRect(x: 0, y: a - 0.5, width: bounds.width, height: 1)).fill()
    }

    private func drawRuler() {
        let horizontal = orientation == .horizontal
        let w = bounds.width, h = bounds.height
        defer {
            NSColor.separatorColor.setFill()
            (horizontal ? NSRect(x: 0, y: h - 1, width: w, height: 1) : NSRect(x: w - 1, y: 0, width: 1, height: h)).fill()
            drawPointerLine()
        }
        if showsBeats { drawBeats(); return }
        let attributes = rulerLabelAttributes
        for tick in rulerTicks() {
            let a = tick.axis
            (tick.major ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
            let len = tick.major ? (horizontal ? h : w) : rulerMinorLength
            (horizontal ? NSRect(x: a - 0.5, y: h - len, width: 1, height: len)
                        : NSRect(x: w - len, y: a - 0.5, width: len, height: 1)).fill()
            if let label = tick.label, let frame = tick.labelFrame {
                NSAttributedString(string: label, attributes: attributes).draw(at: frame.origin)
            }
        }
    }

    /// Axis position of the playhead line, if it is drawn (for the state dump too).
    var playheadAxis: CGFloat? {
        guard let state, state.audio != nil else { return nil }
        let a = axis(ofTime: state.playhead)
        return a >= 0 && a <= timeLength ? a : nil
    }

    /// Axis position of the last-playback-start line, if it is drawn.
    var lastStartAxis: CGFloat? {
        guard let state, state.audio != nil else { return nil }
        let a = axis(ofTime: state.lastStart)
        return a >= 0 && a <= timeLength ? a : nil
    }

    /// The last start first, so the playhead covers it where they coincide.
    private func drawLines() {
        for (axis, color) in [(lastStartAxis, NSColor.lastStartColor), (playheadAxis, NSColor.systemRed)] {
            guard let a = axis else { continue }
            color.setFill()
            (orientation == .horizontal ? NSRect(x: a - 0.75, y: 0, width: 1.5, height: bounds.height)
                                        : NSRect(x: 0, y: a - 0.75, width: bounds.width, height: 1.5)).fill()
        }
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func hover(at p: CGPoint) -> Hover {
        guard let state, let audio = state.audio else { return .none }
        if isRuler {
            // Beat marks first (beats mode, stopped), the nearest within reach.
            if showsBeats, !state.isPlaying,
               let m = beatMarks().min(by: { abs($0.axis - axisPosition(p)) < abs($1.axis - axisPosition(p)) }),
               abs(m.axis - axisPosition(p)) <= Self.edgeTolerance {
                return .beat(sample: m.sample)
            }
            // Then only the last-start line (with the playhead if they coincide while stopped).
            guard abs(axisPosition(p) - axis(ofTime: state.lastStart)) <= Self.edgeTolerance else { return .none }
            var g = Grab(time: state.lastStart)
            g.lastStart = true
            g.playhead = !state.isPlaying && abs(state.playhead - state.lastStart) <= 1 / audio.sampleRate
            return .lines(g)
        }
        let sel = state.selection
        enum Line { case startEdge, endEdge, playhead, lastStart }
        var lines: [(Line, Double)] = []
        if let sel { lines += [(.startEdge, sel.lowerBound), (.endEdge, sel.upperBound)] }
        if !state.isPlaying { lines.append((.playhead, state.playhead)) }
        lines.append((.lastStart, state.lastStart))
        let pos = axisPosition(p)
        if let nearest = lines.min(by: { abs(pos - axis(ofTime: $0.1)) < abs(pos - axis(ofTime: $1.1)) }),
           abs(pos - axis(ofTime: nearest.1)) <= Self.edgeTolerance {
            var g = Grab(time: nearest.1)
            for (line, t) in lines where line == nearest.0 || abs(t - nearest.1) <= 1 / audio.sampleRate {
                switch line {
                case .startEdge: if !g.edge || line == nearest.0 { g.startEdge = true; g.endEdge = false }
                case .endEdge: if !g.edge || line == nearest.0 { g.endEdge = true; g.startEdge = false }
                case .playhead: g.playhead = true
                case .lastStart: g.lastStart = true
                }
            }
            return .lines(g)
        }
        guard let sel else { return .none }
        return pos > axis(ofTime: sel.lowerBound) && pos < axis(ofTime: sel.upperBound) ? .inside : .none
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited,
                                                              .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Edge: resize arrows along the time axis; inside the selection: open hand (closed while
    /// moving); otherwise the arrow. Modifier drags (pan, extend) keep the arrow.
    private func updateCursor(at p: CGPoint, flags: NSEvent.ModifierFlags) {
        let cursor: NSCursor, name: String
        if isRuler {
            // The beat mark under the pointer, for Backspace.
            if case let .beat(sample) = hover(at: p), drag == nil, bounds.contains(p) {
                state?.hoveredBeatSample = sample
            } else if drag == nil {
                state?.hoveredBeatSample = nil
            }
        }
        if case .move = drag {
            (cursor, name) = (.closedHand, "closedHand")
        } else if case .beat = drag {
            (cursor, name) = (.closedHand, "closedHand")
        } else if case .lines = drag {
            (cursor, name) = orientation == .horizontal ? (.columnResize, "columnResize") : (.rowResize, "rowResize")
        } else if drag != nil || !flags.intersection([.option, .shift, .command]).isEmpty {
            (cursor, name) = (.arrow, "arrow")
        } else {
            switch hover(at: p) {
            case .lines:
                (cursor, name) = orientation == .horizontal ? (.columnResize, "columnResize") : (.rowResize, "rowResize")
            case .inside, .beat: (cursor, name) = (.openHand, "openHand")
            case .none: (cursor, name) = (.arrow, "arrow")
            }
        }
        cursor.set()
        cursorName = name
    }

    /// Spectrogram mode: whether a point is under the spectrum pane (milestone 9), which covers
    /// the main pane's left side (horizontal) or bottom (vertical).
    private func underSpectrum(_ p: CGPoint) -> Bool {
        guard isSpectrogram, state?.audio != nil else { return false }
        let cover = SpectrumConstants.thickness + 1
        return orientation == .horizontal ? p.x < cover : p.y > bounds.height - cover
    }

    /// Under the spectrum pane (no drag): no pointer line, the arrow cursor.
    private func leaveForSpectrum(_ p: CGPoint) -> Bool {
        guard drag == nil, underSpectrum(p) else { return false }
        if state?.pointer?.pane == name { state?.pointer = nil }
        NSCursor.arrow.set(); cursorName = "arrow"
        return true
    }

    override func cursorUpdate(with event: NSEvent) {
        if leaveForSpectrum(location(event)) { return }
        updateCursor(at: location(event), flags: event.modifierFlags)
    }
    override func mouseMoved(with event: NSEvent) {
        if leaveForSpectrum(location(event)) { return }
        updatePointer(location(event))
        updateCursor(at: location(event), flags: event.modifierFlags)
    }
    override func mouseEntered(with event: NSEvent) { if !leaveForSpectrum(location(event)) { updatePointer(location(event)) } }
    override func mouseExited(with event: NSEvent) {
        if state?.pointer?.pane == name { state?.pointer = nil }
        if isRuler, drag == nil { state?.hoveredBeatSample = nil }
        if drag == nil { NSCursor.arrow.set(); cursorName = "arrow" }
    }

    /// The pointer line follows the pointer's time (also while dragging).
    private func updatePointer(_ p: CGPoint) {
        guard let state, timeLength > 0 else { return }
        if bounds.contains(p) || drag != nil {
            state.pointer = (name, Double(axisPosition(p) / timeLength))
        } else if state.pointer?.pane == name {
            state.pointer = nil
        }
    }
    override func flagsChanged(with event: NSEvent) {
        if let w = window { updateCursor(at: convert(w.mouseLocationOutsideOfEventStream, from: nil), flags: event.modifierFlags) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let state, state.audio != nil else { return }
        let p = location(event)
        pressPoint = p
        dragged = false
        let t = time(atAxis: clampedAxis(p))
        if event.modifierFlags.contains(.option) {
            drag = panDrag(at: p)
        } else if isRuler, case let .beat(sample) = hover(at: p) {
            let bt = Double(sample) / (state.audio?.sampleRate ?? 44100)
            drag = .beat(sample: sample, placedIndex: nil, offset: bt - time(atAxis: axisPosition(p)))
        } else if isRuler, hover(at: p) == .none {
            let playing = state.isPlaying
            drag = .seek(playing: playing)
            seek(to: t)
        } else if !isRuler, event.modifierFlags.contains(.shift), let sel = state.selection {
            // Keep the end farther from the click; the nearer one follows the pointer.
            let anchor = abs(t - sel.lowerBound) < abs(t - sel.upperBound) ? sel.upperBound : sel.lowerBound
            drag = .select(anchor: anchor, extend: true)
        } else if case let h = hover(at: p), h != .none {
            let pt = time(atAxis: axisPosition(p))
            switch h {
            case let .lines(g):
                let anchor = g.startEdge ? state.selection?.upperBound : g.endEdge ? state.selection?.lowerBound : nil
                drag = .lines(g, anchor: anchor, offset: g.time - pt)
            default:
                if let sel = state.selection { drag = .move(original: sel, pressTime: pt) }
            }
        } else {
            drag = .select(anchor: t, extend: false)
        }
        updateCursor(at: p, flags: event.modifierFlags)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, state?.audio != nil else { return }
        drag = panDrag(at: location(event))
    }

    private func panDrag(at p: CGPoint) -> Drag {
        let semitone = isSpectrogram ? state.map { $0.freqBottom + Double(crossFromLow(p)) / SpectrogramConstants.pointsPerSemitone } : nil
        return .pan(grabbedTime: time(atAxis: axisPosition(p)), grabbedSemitone: semitone)
    }

    override func mouseDragged(with event: NSEvent) { updatePointer(location(event)); dragTo(location(event)) }
    override func otherMouseDragged(with event: NSEvent) { updatePointer(location(event)); dragTo(location(event)) }

    private func clampedAxis(_ p: CGPoint) -> CGFloat { min(max(axisPosition(p), 0), timeLength) }

    /// Ruler press: playing, playback jumps to `t`; stopped, the playhead goes there.
    private func seek(to t: Double) {
        guard let state else { return }
        if state.isPlaying { state.startPlayback(at: t) } else { state.dragPlayhead(to: t) }
    }

    private func dragTo(_ p: CGPoint) {
        guard let state, let drag else { return }
        if !dragged, hypot(p.x - pressPoint.x, p.y - pressPoint.y) >= 2 {
            dragged = true
            if case .select(_, false) = drag { state.newSelectionStarted() }
            switch drag {
            case .move, .select(_, true): state.player.core.setSelectionDragging(true)
            case let .lines(g, _, _) where g.edge: state.player.core.setSelectionDragging(true)
            default: break
            }
            if case .pan = drag { state.manualViewChange() }
            if case let .beat(sample, nil, offset) = drag {
                let k = state.beginBeatDrag(sample: sample)
                self.drag = .beat(sample: sample, placedIndex: k, offset: offset)
            }
        }
        guard let drag = self.drag else { return }
        switch drag {
        case let .select(anchor, extend):
            if dragged || extend { state.select(anchor, time(atAxis: clampedAxis(p))) }
            if dragged && !extend { state.newSelectionChanged() }
        case let .pan(grabbed, semitone):
            guard timeLength > 0 else { return }
            state.panTo(start: grabbed - Double(axisPosition(p) / timeLength) * state.viewLength)
            if let semitone { state.setFreqLow(semitone - Double(crossFromLow(p)) / SpectrogramConstants.pointsPerSemitone) }
        case let .lines(g, anchor, offset):
            // The lines keep their offset from the pointer, limited to the visible range and the file.
            guard dragged else { return }
            let t = min(max(time(atAxis: axisPosition(p)) + offset, state.viewStart, 0), state.viewEnd, state.duration)
            if let anchor { state.select(anchor, t) }
            if g.playhead { state.dragPlayhead(to: t) }
            if g.lastStart { state.dragLastStart(to: t) }
        case let .move(original, pressTime):
            guard dragged else { return }
            state.moveSelection(from: original, by: time(atAxis: axisPosition(p)) - pressTime)
        case let .seek(playing):
            if !playing { state.dragPlayhead(to: time(atAxis: clampedAxis(p))) }
        case let .beat(_, placedIndex, offset):
            guard dragged, let k = placedIndex else { return }
            state.dragBeat(placedIndex: k, to: time(atAxis: axisPosition(p)) + offset)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let state, let drag else { return }
        let p = location(event)
        dragTo(p)
        if !bounds.contains(p), state.pointer?.pane == name { state.pointer = nil }
        // A click without a drag clears the selection (also on its edges or inside it).
        state.player.core.setSelectionDragging(false)
        let clicked = time(atAxis: axisPosition(p))
        switch drag {
        case let .select(_, extend): if !dragged && !extend { state.clickedToClear(at: clicked) }
        case .lines where isRuler: if !dragged { seek(to: time(atAxis: clampedAxis(p))) }
        case .lines, .move: if !dragged { state.clickedToClear(at: clicked) }
        case .pan, .seek: break
        case .beat:
            // A click without a drag acts as a plain strip press.
            if dragged { state.endBeatDrag() } else { seek(to: time(atAxis: clampedAxis(p))) }
        }
        self.drag = nil
        updateCursor(at: p, flags: event.modifierFlags)
    }

    override func otherMouseUp(with event: NSEvent) {
        if case .pan = drag { dragTo(location(event)) }
        drag = nil
    }

    // MARK: Scroll and pinch

    /// Command-scroll zoom: the axis chosen at the gesture's start (true: time, false: amplitude).
    private(set) var zoomTimeAxis: Bool?

    override func scrollWheel(with event: NSEvent) {
        guard let state, state.audio != nil, timeLength > 0 else { return }
        // Line-based wheels report small deltas; scale them to roughly 10 points per line.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX * scale, dy = event.scrollingDeltaY * scale
        state.lastScrollDelta = [Double(dx), Double(dy), event.hasPreciseScrollingDeltas ? 1 : 0]
        state.manualViewChange()
        if event.modifierFlags.contains(.command) {
            // Scrolling along the time axis zooms time; across it, amplitude. Positive zooms in,
            // except vertical scrolling in horizontal mode: negative (upwards) zooms in.
            // One axis per gesture: the one with the larger delta in the gesture's first event
            // (every event of a wheel without gesture phases).
            let (dTime, dAmp) = orientation == .horizontal ? (dx, -dy) : (dy, dx)
            if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) { zoomTimeAxis = nil }
            if zoomTimeAxis == nil, dTime != 0 || dAmp != 0 { zoomTimeAxis = abs(dTime) >= abs(dAmp) }
            if zoomTimeAxis == true, dTime != 0 {
                state.zoom(by: exp(Double(dTime) * 0.01), anchor: time(atAxis: clampedAxis(location(event))))
            }
            if zoomTimeAxis == false, dAmp != 0 { state.zoomAmplitude(by: exp(Double(dAmp) * 0.01)) }
        } else {
            scrollPan(dx: dx, dy: dy)
        }
    }

    /// A plain scroll's pan (also the `scrollpan` verification hook, which can pass the fractional
    /// deltas synthesized events can't carry).
    func scrollPan(dx: CGFloat, dy: CGFloat) {
        guard let state, timeLength > 0 else { return }
        // Content follows the scroll: a positive delta brings earlier times into view.
        let d = orientation == .horizontal ? dx + dy : dy
        state.pan(by: -Double(d / timeLength) * state.viewLength)
    }

    override func magnify(with event: NSEvent) {
        guard let state, state.audio != nil else { return }
        state.manualViewChange()
        state.zoom(by: 1 + Double(event.magnification), anchor: time(atAxis: clampedAxis(location(event))))
    }
}

struct WaveformView: NSViewRepresentable {
    let name: String
    let state: AppState
    let background: NSColor
    var isRuler = false

    func makeNSView(context: Context) -> WaveformNSView { WaveformNSView() }

    func updateNSView(_ view: WaveformNSView, context: Context) {
        view.name = name
        view.isRuler = isRuler
        view.state = state
        view.background = background
        // Read the observed properties here so SwiftUI calls this again when they change.
        _ = (state.audio?.mono.count, state.orientation, state.viewStart, state.viewEnd, state.selection,
             state.amplitudeZoomDB, state.playhead, state.lastStart, state.isPlaying)
        if name == "main" {
            _ = (state.mainMode, state.windowLengthMs, state.freqLow, state.spectrogramVersion,
                 state.mainCrossLength, state.mainAxisLength, state.loadID)
            view.reportSize()
            _ = (state.beats, state.gridDenominator, state.gridLinesShown)
        }
        if name == "navigator" { _ = (state.mainMode, state.windowLengthMs) }
        if isRuler { _ = (state.beats.count, state.showBeats, state.pointer?.fraction, state.pointer?.pane) }
        view.needsDisplay = true
    }
}

/// Navigator scrollbar along the time axis. Always the legacy (non-overlay) style.
final class TimeScroller: NSScroller {
    var state: AppState?

    override class var isCompatibleWithOverlayScrollers: Bool { false }

    func update() {
        guard let state, state.duration > 0 else {
            isEnabled = false; knobProportion = 1; doubleValue = 0; return
        }
        let (lo, hi) = state.viewLimits
        let rest = hi - lo - state.viewLength
        isEnabled = rest > 1e-12
        knobProportion = CGFloat(state.viewLength / (hi - lo))
        doubleValue = isEnabled ? (state.viewStart - lo) / rest : 0
    }

    /// Position of the playhead mark along the track (points from the scroller's start).
    var playheadMark: CGFloat? { mark(state?.playhead) }

    /// Position of the last-playback-start mark along the track.
    var lastStartMark: CGFloat? { mark(state?.lastStart) }

    private func mark(_ t: Double?) -> CGFloat? {
        guard let state, state.audio != nil, let t else { return nil }
        let (lo, hi) = state.viewLimits
        let slot = rect(for: .knobSlot)
        let vertical = bounds.height > bounds.width
        let (start, length) = vertical ? (slot.minY, slot.height) : (slot.minX, slot.width)
        return start + CGFloat((t - lo) / (hi - lo)) * length
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (m, color) in [(lastStartMark, NSColor.lastStartColor), (playheadMark, NSColor.systemRed)] {
            guard let m else { continue }
            color.setFill()
            (bounds.height > bounds.width ? NSRect(x: 0, y: m - 1, width: bounds.width, height: 2)
                                          : NSRect(x: m - 1, y: 0, width: 2, height: bounds.height)).fill()
        }
    }

    @objc func scrolled(_ sender: NSScroller) {
        guard let state else { return }
        state.manualViewChange()
        let (lo, hi) = state.viewLimits
        let rest = hi - lo - state.viewLength
        switch hitPart {
        case .decrementPage: state.panTo(start: state.viewStart - state.viewLength)
        case .incrementPage: state.panTo(start: state.viewStart + state.viewLength)
        default: state.panTo(start: lo + doubleValue * rest)
        }
        update()
    }
}

struct TimeScrollerView: NSViewRepresentable {
    let state: AppState
    let vertical: Bool

    static var thickness: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }

    func makeNSView(context: Context) -> TimeScroller {
        // NSScroller takes its orientation from the frame it is created with.
        let s = TimeScroller(frame: vertical ? NSRect(x: 0, y: 0, width: 15, height: 100)
                                             : NSRect(x: 0, y: 0, width: 100, height: 15))
        s.scrollerStyle = .legacy
        s.controlSize = .regular
        s.target = s
        s.action = #selector(TimeScroller.scrolled(_:))
        return s
    }

    func updateNSView(_ view: TimeScroller, context: Context) {
        view.state = state
        _ = (state.audio?.duration, state.viewStart, state.viewEnd, state.playhead, state.lastStart)
        view.update()
        view.needsDisplay = true
    }
}

extension NSColor {
    /// The playhead's red, desaturated: the last-playback-start line.
    static var lastStartColor: NSColor {
        NSColor(name: nil) { _ in
            guard let red = NSColor.systemRed.usingColorSpace(.sRGB) else { return .systemGray }
            return NSColor(hue: red.hueComponent, saturation: red.saturationComponent * 0.35,
                           brightness: red.brightnessComponent * 0.9, alpha: 1)
        }
    }
}

// MARK: Ruler layout and labels

/// Major tick steps (seconds).
let rulerSteps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30,
                            60, 120, 300, 600, 900, 1800, 3600, 7200, 18000, 36000]
/// Space between a tick and its label (right of it / below it).
let rulerLabelOffset: CGFloat = 3
/// Minimum space between neighbouring labels.
let rulerLabelGap: CGFloat = 30
let rulerMinMinorSpacing: CGFloat = 4
let rulerMinorLength: CGFloat = 4
/// Dash and gap length of a dotted big tick (`firstBeat: computed`).
let rulerDash: CGFloat = 2
let rulerDotDiameter: CGFloat = 3
/// Height of the strip in horizontal mode.
let rulerHorizontalThickness: CGFloat = 18
@MainActor private let rulerFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
@MainActor private var rulerLabelAttributes: [NSAttributedString.Key: Any] {
    [.font: rulerFont, .foregroundColor: NSColor.secondaryLabelColor]
}

@MainActor func rulerLabelSize(_ s: String) -> CGSize {
    let size = NSAttributedString(string: s, attributes: [.font: rulerFont]).size()
    return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
}

/// Width of the strip in vertical mode: the longest time label of the file (3 decimals) or bar
/// number, plus padding.
@MainActor func rulerVerticalThickness(duration: Double, bars: Int = 0) -> CGFloat {
    rulerLabelOffset + max(rulerLabelSize(formatRulerTime(duration, step: 0.001)).width,
                           rulerLabelSize(String(bars)).width) + 5
}

/// Minor divisions of a major step: 5 for 1·10ⁿ and 5·10ⁿ, 4 for 2·10ⁿ, 3 for 15 s / 15 min,
/// 6 for 30 s / 30 min (minutes and hours count like seconds).
func rulerMinorParts(_ step: Double) -> Int {
    var v = step >= 60 ? step / 60 : step
    if step >= 3600 { v = step / 3600 }
    while v >= 10 { if v == 15 || v == 30 { break }; v /= 10 }
    while v < 1 { v *= 10 }
    switch Int(v.rounded()) {
    case 2: return 4
    case 15: return 3
    case 30, 3: return 6
    default: return 5
    }
}

/// `m:ss` with as many decimals as the step needs.
func formatRulerTime(_ t: Double, step: Double) -> String {
    let decimals = step >= 1 ? 0 : max(0, Int((-log10(step) - 1e-9).rounded(.up)))
    let ms = Int((t * 1000).rounded())
    var s = String(format: "%d:%02d", ms / 60000, ms / 1000 % 60)
    if decimals > 0 { s += "." + String(String(format: "%03d", ms % 1000).prefix(decimals)) }
    return s
}
