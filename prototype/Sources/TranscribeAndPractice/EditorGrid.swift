import AppKit
import SwiftUI

/// Editor grid (milestone 11, experimental): bar, beat and grid lines in the main pane.
enum GridKind: String, CaseIterable { case straight, triplet, tuplet }

enum GridConstants {
    static let straight = [1, 2, 4, 8, 16, 32, 64]
    static let triplet = [3, 6, 12, 24, 48]
    static let tupletRange = 1...64
    /// A kind of line is hidden while two neighbouring visible lines (of it or a stronger kind)
    /// are closer than this (points).
    static let minSpacing: CGFloat = 6
    /// Core widths (points) of the bar and beat lines; each has a 1-point border on both sides.
    static let barWidth: CGFloat = 3, beatWidth: CGFloat = 1
    /// Dash length (points) of the alternating grid line style; the dashes move along the line
    /// by `dashStep` points every `dashInterval` seconds.
    static let dash: CGFloat = 4
    static let dashStep: CGFloat = 0.5, dashInterval = 1.0 / 16
}

struct EditorLine: Equatable {
    enum Kind: String { case bar, beat, grid }
    var kind: Kind
    var time: Double
}

/// A stretch of beats the grid divides: from a bar start to the next one (or the last beat), or,
/// `backward`, the pickup before the first bar start, divided from its end. Beat indices.
struct GridSegment { var from: Int, to: Int, backward: Bool }

func gridSegments(barStarts: [Bool]) -> [GridSegment] {
    let bars = barStarts.indices.filter { barStarts[$0] }
    guard let first = bars.first, let last = barStarts.indices.last else { return [] }
    var out: [GridSegment] = []
    if first > 0 { out.append(GridSegment(from: 0, to: first, backward: true)) }
    for (k, s) in bars.enumerated() {
        let e = k + 1 < bars.count ? bars[k + 1] : last
        if e > s { out.append(GridSegment(from: s, to: e, backward: false)) }
    }
    return out
}

/// Time at a fractional beat index (linear inside a beat interval).
private func beatTime(_ p: Double, _ t: [Double]) -> Double {
    let i = min(max(Int(p.rounded(.down)), 0), t.count - 2)
    return t[i] + (p - Double(i)) * (t[i + 1] - t[i])
}

/// Bar lines at the bar starts, beat lines at the other beats, and grid lines every
/// 1/`gridDenominator` note: in each bar from its start until the next bar start (the last bar:
/// until the last beat), and in the pickup before the first bar start counted backwards from
/// it. A beat interval counts as one `beatNote`; inside it, time is interpolated linearly. Grid
/// lines that fall on a beat are left out. Only lines in `range` are returned.
func editorLines(beats: [Beat], barStarts: [Bool], sampleRate fs: Double, gridDenominator: Int?,
                 range: ClosedRange<Double>) -> [EditorLine] {
    guard fs > 0 else { return [] }
    let t = beats.map { Double($0.sample) / fs }
    var lines: [EditorLine] = []
    for i in beats.indices where range.contains(t[i]) {
        lines.append(EditorLine(kind: barStarts[i] ? .bar : .beat, time: t[i]))
    }
    if let d = gridDenominator, d > 0 {
        // Step in beats: (1/d) / beatNote.
        let step = Rational(1, d) / BeatConstants.beatNote
        for g in gridSegments(barStarts: barStarts) where t[g.to] >= range.lowerBound && t[g.from] <= range.upperBound {
            let len = Rational(g.to - g.from, 1)
            var k = 1
            while true {
                let dist = Rational(k * step.num, step.den) // beats from the counting end
                guard dist < len else { break }
                k += 1
                let pos = g.backward ? len - dist : dist // beats from the segment start
                if pos.den == 1 { continue } // on a beat
                let time = beatTime(Double(g.from) + Double(pos.num) / Double(pos.den), t)
                if range.contains(time) { lines.append(EditorLine(kind: .grid, time: time)) }
            }
        }
    }
    return lines.sorted { $0.time < $1.time }
}

/// The grid cell containing `time`, as beat positions (beat index + fraction, exact) and times:
/// one grid step (1/`gridDenominator` note) counted from the bar start, cut at the next bar start
/// (in the pickup: counted backwards from the first bar start and cut at the first beat; in the
/// last bar: cut at the last beat). Nil outside the beats.
func gridCellSpan(beats: [Beat], barStarts: [Bool], sampleRate fs: Double, gridDenominator d: Int,
                  time: Double) -> (startPos: Rational, endPos: Rational, start: Double, end: Double)? {
    guard fs > 0, d > 0, beats.count >= 2 else { return nil }
    let t = beats.map { Double($0.sample) / fs }
    guard time >= t[0], time < t[t.count - 1],
          let g = gridSegments(barStarts: barStarts).first(where: { time >= t[$0.from] && time < t[$0.to] }) else { return nil }
    let step = Rational(1, d) / BeatConstants.beatNote
    let stepD = step.doubleValue
    // Fractional beat index of `time`, from the segment start.
    let i = (g.from..<g.to).last { t[$0] <= time } ?? g.from
    let p = Double(i) + (time - t[i]) / (t[i + 1] - t[i]) - Double(g.from)
    let len = Rational(g.to - g.from, 1)
    let eps = 1e-9
    let a: Rational, b: Rational
    if g.backward {
        let k = Int(((len.doubleValue - p) / stepD - eps).rounded(.down))
        a = max(len - Rational(k + 1, 1) * step, Rational(0, 1))
        b = len - Rational(k, 1) * step
    } else {
        let k = Int((p / stepD + eps).rounded(.down))
        a = Rational(k, 1) * step
        b = min(Rational(k + 1, 1) * step, len)
    }
    let s = Rational(g.from, 1) + a, e = Rational(g.from, 1) + b
    return (s, e, beatTime(s.doubleValue, t), beatTime(e.doubleValue, t))
}

extension WaveformNSView {
    /// The editor lines drawn in this pane (main pane only; grid lines only in spectrogram mode),
    /// after hiding crowded kinds, with their axis positions.
    func visibleEditorLines() -> [(line: EditorLine, axis: CGFloat)] {
        guard name == "main", let state, let audio = state.audio, !state.beats.isEmpty, state.viewLength > 0 else { return [] }
        let len = orientation == .horizontal ? bounds.width : bounds.height
        let all = editorLines(beats: state.beats, barStarts: state.beatPositions.map(\.isBarStart), sampleRate: audio.sampleRate,
                              gridDenominator: isSpectrogram && state.gridPanelOpen ? state.gridDenominator : nil,
                              range: state.viewStart...state.viewEnd)
        func axis(_ t: Double) -> CGFloat { CGFloat((t - state.viewStart) / state.viewLength) * len }
        func crowded(_ kinds: Set<EditorLine.Kind>) -> Bool {
            let a = all.filter { kinds.contains($0.kind) }.map { axis($0.time) }
            return zip(a, a.dropFirst()).contains { $1 - $0 < GridConstants.minSpacing }
        }
        var shown: Set<EditorLine.Kind> = [.bar, .beat, .grid]
        if crowded([.bar, .beat, .grid]) { shown.remove(.grid) }
        if crowded([.bar, .beat]) { shown.remove(.beat) }
        if crowded([.bar]) { shown.remove(.bar) }
        return all.filter { shown.contains($0.kind) }.map { ($0, axis($0.time)) }
    }

    /// Bar and beat lines: white 50 % core with 1-point black 50 % borders, across the whole pane.
    /// Grid lines: the alternating style (`strokeAlternating`).
    func drawEditorLines() {
        let lines = visibleEditorLines()
        guard !lines.isEmpty else { return }
        let horizontal = orientation == .horizontal
        let cross = horizontal ? bounds.height : bounds.width
        // Along the time axis from a, w wide; across from c0, l long.
        func rect(_ a: CGFloat, _ w: CGFloat, _ c0: CGFloat = 0, _ l: CGFloat? = nil) -> NSRect {
            let l = l ?? cross
            return horizontal ? NSRect(x: a, y: c0, width: w, height: l) : NSRect(x: c0, y: a, width: l, height: w)
        }
        let core = NSBezierPath(), border = NSBezierPath(), grid = NSBezierPath()
        for (line, a) in lines {
            if line.kind == .grid {
                let c = pixelCentre(a)
                grid.move(to: horizontal ? CGPoint(x: c, y: 0) : CGPoint(x: 0, y: c))
                grid.line(to: horizontal ? CGPoint(x: c, y: cross) : CGPoint(x: cross, y: c))
                continue
            }
            let w = line.kind == .bar ? GridConstants.barWidth : GridConstants.beatWidth
            let a0 = (a - w / 2).rounded()
            core.appendRect(rect(a0, w))
            border.appendRect(rect(a0 - 1, 1))
            border.appendRect(rect(a0 + w, 1))
        }
        NSColor.black.withAlphaComponent(0.5).setFill()
        border.fill()
        NSColor.white.withAlphaComponent(0.5).setFill()
        core.fill()
        strokeAlternating(grid)
    }

    /// The centre of the 1-point column nearest to `a`, for crisp 1-point lines.
    func pixelCentre(_ a: CGFloat) -> CGFloat { (a - 0.5).rounded() + 0.5 }

    /// Grid line style (milestone 13): 1 point wide, alternating dashes of 50 % black and 50 %
    /// white, visible on any background, moving along the line ("marching ants"). `opacity`:
    /// of both colours (milestone 14: 1 for the note handles).
    func strokeAlternating(_ path: NSBezierPath, opacity: CGFloat = 0.5) {
        guard !path.isEmpty else { return }
        path.lineWidth = 1
        usedDashes = true
        for (color, phase) in [(NSColor.black, dashPhase), (NSColor.white, dashPhase + GridConstants.dash)] {
            path.setLineDash([GridConstants.dash, GridConstants.dash], count: 2, phase: phase)
            color.withAlphaComponent(opacity).setStroke()
            path.stroke()
        }
    }

    // MARK: Hover cell (milestone 13)

    /// The grid cell under a point of the spectrogram: one grid step in time (`gridCellSpan`) and
    /// the note under the pointer (note ± ½). Nil outside the beats or the note range.
    func gridCell(at p: CGPoint) -> GridCell? {
        guard isSpectrogram, let state, let audio = state.audio, !state.beats.isEmpty, timeLength > 0 else { return nil }
        let t = state.viewStart + Double(axisPosition(p) / timeLength) * state.viewLength
        let s = state.freqBottom + Double(crossFromLow(p)) / SpectrogramConstants.pointsPerSemitone
        guard s >= 0, s < SpectrogramConstants.rangeSemitones else { return nil }
        guard let (p0, p1, t0, t1) = gridCellSpan(beats: state.beats, barStarts: state.beatPositions.map(\.isBarStart),
                                          sampleRate: audio.sampleRate, gridDenominator: state.gridDenominator, time: t)
        else { return nil }
        let k = Int(s.rounded(.down))
        return GridCell(startPos: p0, endPos: p1, start: t0, end: t1, note: SpectrogramConstants.lowestNote + k)
    }

    /// The hover cell, unless the pointer is over a note (milestone 14).
    func visibleGridCell(at p: CGPoint) -> GridCell? {
        hoveredSegment(at: p) == nil ? gridCell(at: p) : nil
    }

    /// The cell's rectangle in view coordinates (on whole points), `shift` semitones higher.
    func rect(of c: GridCell, shift: Double = 0) -> NSRect {
        guard let state else { return .zero }
        let a0 = pixelCentre(axis(ofTime: c.start)), a1 = pixelCentre(axis(ofTime: c.end))
        let k = Double(c.note - SpectrogramConstants.lowestNote) + shift
        let lo = pixelCentre(CGFloat((k - state.freqBottom) * SpectrogramConstants.pointsPerSemitone))
        let hi = pixelCentre(CGFloat((k + 1 - state.freqBottom) * SpectrogramConstants.pointsPerSemitone))
        return orientation == .horizontal
            ? NSRect(x: a0, y: bounds.height - hi, width: a1 - a0, height: hi - lo)
            : NSRect(x: lo, y: a0, width: hi - lo, height: a1 - a0)
    }

    /// Shifts (semitones) of the hover cell copies: 12·log2(i) for the harmonics i = 2…n.
    func harmonicShifts() -> [Double] {
        guard let n = state?.harmonics, n >= 2 else { return [] }
        return (2...n).map { 12 * log2(Double($0)) }
    }

    /// The hover cell and, with the harmonics setting, its copies 12·log2(i) semitones higher
    /// (only drawn; placing a note is not affected).
    /// Milestone 14: over a note, the note's harmonic copies instead (see `drawNoteHarmonics`).
    func drawHoverCell() {
        guard let p = hoverPoint else { return }
        if hoveredSegment(at: p) != nil { drawNoteHarmonics(); return }
        guard let c = gridCell(at: p) else { return }
        let path = NSBezierPath(rect: rect(of: c))
        for s in harmonicShifts() { path.append(NSBezierPath(rect: rect(of: c, shift: s))) }
        strokeAlternating(path)
    }
}

/// A grid cell: from one division line to the next, one note high.
struct GridCell: Equatable {
    /// Beat positions (beat index + fraction).
    var startPos: Rational, endPos: Rational
    /// Seconds.
    var start: Double, end: Double
    /// MIDI note number.
    var note: Int
}

/// Toolbar "Grid" control: a button showing the current value, opening a panel with the grid kind
/// and the note values.
struct GridControl: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 6) {
            Button { state.gridPanelOpen.toggle() } label: {
                Text("Grid \(state.gridLabel)").monospacedDigit()
            }
            .help("Grid")
            .accessibilityLabel("Grid")
            .popover(isPresented: $state.gridPanelOpen, arrowEdge: .bottom) { GridPanel().padding(12) }
        }
        .padding(.horizontal, 6)
    }
}

private struct GridPanel: View {
    @Environment(AppState.self) private var state
    @State private var tupletText = ""

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $state.gridKind) {
                Text("Straight").tag(GridKind.straight)
                Text("Triplet").tag(GridKind.triplet)
                Text("Tuplet").tag(GridKind.tuplet)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            Divider()
            switch state.gridKind {
            case .straight: values(GridConstants.straight, selection: $state.gridStraight)
            case .triplet: values(GridConstants.triplet, selection: $state.gridTriplet)
            case .tuplet:
                HStack(spacing: 4) {
                    Text("1 /")
                    TextField("Tuplet", text: $tupletText)
                        .labelsHidden()
                        .accessibilityLabel("Tuplet value")
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(applyTuplet)
                        .onChange(of: tupletText) { applyTuplet() }
                }
                .onAppear { tupletText = String(state.gridTuplet) }
            }
        }
        .frame(width: 220, alignment: .leading)
    }

    private func applyTuplet() {
        if let n = Int(tupletText), GridConstants.tupletRange.contains(n) { state.gridTuplet = n }
    }

    private func values(_ list: [Int], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(list, id: \.self) { d in
                Button {
                    selection.wrappedValue = d
                } label: {
                    HStack {
                        Image(systemName: "checkmark").opacity(selection.wrappedValue == d ? 1 : 0)
                        Text("1/\(d)").monospacedDigit()
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
                .accessibilityLabel("1/\(d)")
            }
        }
    }
}
