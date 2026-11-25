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
}

struct EditorLine: Equatable {
    enum Kind: String { case bar, beat, grid }
    var kind: Kind
    var time: Double
}

/// Bar lines at the downbeats, beat lines at the other beats, and grid lines every 1/`gridDenominator`
/// note from each downbeat until the next one (between the first and the last downbeat only). A
/// beat interval counts as one `beatNote`; inside it, time is interpolated linearly. Grid lines
/// that fall on a beat are left out. Only lines in `range` are returned.
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
        let bars = beats.indices.filter { barStarts[$0] }
        for (s, e) in zip(bars, bars.dropFirst()) where t[e] >= range.lowerBound && t[s] <= range.upperBound {
            var k = 1
            while true {
                let pos = Rational(k * step.num, step.den) // beats from the bar start
                guard pos < Rational(e - s, 1) else { break }
                k += 1
                if pos.den == 1 { continue } // on a beat
                let whole = pos.num / pos.den
                let frac = Double(pos.num - whole * pos.den) / Double(pos.den)
                let a = t[s + whole], b = t[s + whole + 1]
                let time = a + frac * (b - a)
                if range.contains(time) { lines.append(EditorLine(kind: .grid, time: time)) }
            }
        }
    }
    return lines.sorted { $0.time < $1.time }
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

    /// Grid line style (milestone 13): 1 point wide, alternating 1-point dashes of 50 % black and
    /// 50 % white, visible on any background.
    func strokeAlternating(_ path: NSBezierPath) {
        guard !path.isEmpty else { return }
        path.lineWidth = 1
        for (color, phase) in [(NSColor.black, CGFloat(0)), (NSColor.white, CGFloat(1))] {
            path.setLineDash([1, 1], count: 2, phase: phase)
            color.withAlphaComponent(0.5).setStroke()
            path.stroke()
        }
    }

    // MARK: Hover cell (milestone 13)

    /// The grid cell under a point of the spectrogram: between the nearest division lines (bar,
    /// beat or grid lines of the current grid, whether drawn or not) before and after the
    /// pointer's time, and the boundaries (note ± ½) of the note under the pointer. Nil outside
    /// the divided range or the note range.
    func gridCell(at p: CGPoint) -> GridCell? {
        guard isSpectrogram, let state, let audio = state.audio, !state.beats.isEmpty, timeLength > 0 else { return nil }
        let t = state.viewStart + Double(axisPosition(p) / timeLength) * state.viewLength
        let s = state.freqBottom + Double(crossFromLow(p)) / SpectrogramConstants.pointsPerSemitone
        guard s >= 0, s < SpectrogramConstants.rangeSemitones else { return nil }
        let starts = state.beatPositions.map(\.isBarStart)
        func bracket(_ range: ClosedRange<Double>) -> (Double, Double)? {
            let times = editorLines(beats: state.beats, barStarts: starts, sampleRate: audio.sampleRate,
                                    gridDenominator: state.gridDenominator, range: range).map(\.time)
            guard let lo = times.last(where: { $0 <= t }), let hi = times.first(where: { $0 > t }) else { return nil }
            return (lo, hi)
        }
        // Near the view first; the whole file if a side has no line there.
        let near = (state.viewStart - state.viewLength)...(state.viewEnd + state.viewLength)
        guard let (t0, t1) = bracket(near) ?? bracket(0...state.duration) else { return nil }
        let k = Int(s.rounded(.down))
        return GridCell(start: t0, end: t1, note: SpectrogramConstants.lowestNote + k)
    }

    /// The cell's rectangle in view coordinates (on whole points).
    func rect(of c: GridCell) -> NSRect {
        guard let state else { return .zero }
        let a0 = pixelCentre(axis(ofTime: c.start)), a1 = pixelCentre(axis(ofTime: c.end))
        let k = Double(c.note - SpectrogramConstants.lowestNote)
        let lo = pixelCentre(CGFloat((k - state.freqBottom) * SpectrogramConstants.pointsPerSemitone))
        let hi = pixelCentre(CGFloat((k + 1 - state.freqBottom) * SpectrogramConstants.pointsPerSemitone))
        return orientation == .horizontal
            ? NSRect(x: a0, y: bounds.height - hi, width: a1 - a0, height: hi - lo)
            : NSRect(x: lo, y: a0, width: hi - lo, height: a1 - a0)
    }

    func drawHoverCell() {
        guard let p = hoverPoint, let c = gridCell(at: p) else { return }
        strokeAlternating(NSBezierPath(rect: rect(of: c)))
    }
}

/// A grid cell: from one division line to the next, one note high.
struct GridCell: Equatable {
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
