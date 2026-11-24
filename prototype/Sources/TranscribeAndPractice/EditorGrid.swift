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
    /// Core widths (points) of the bar, beat and grid lines; each has a 1-point border on both sides.
    static let barWidth: CGFloat = 3, beatWidth: CGFloat = 1, gridWidth: CGFloat = 1
    /// Grid lines are dotted: dashes this long (points), repeating with this period.
    static let gridDash: CGFloat = 2, gridPeriod: CGFloat = 4
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
func editorLines(beats: [Beat], sampleRate fs: Double, gridDenominator: Int?, range: ClosedRange<Double>) -> [EditorLine] {
    guard fs > 0 else { return [] }
    let t = beats.map { Double($0.sample) / fs }
    var lines: [EditorLine] = []
    for (i, b) in beats.enumerated() where range.contains(t[i]) {
        lines.append(EditorLine(kind: b.isDownbeat ? .bar : .beat, time: t[i]))
    }
    if let d = gridDenominator, d > 0 {
        // Step in beats: (1/d) / beatNote.
        let step = Rational(1, d) / BeatConstants.beatNote
        let bars = beats.indices.filter { beats[$0].isDownbeat }
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
        let all = editorLines(beats: state.beats, sampleRate: audio.sampleRate,
                              gridDenominator: isSpectrogram && state.gridLinesShown ? state.gridDenominator : nil,
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

    /// White 50 % core with 1-point black 50 % borders, across the whole pane.
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
        let core = NSBezierPath(), border = NSBezierPath()
        for (line, a) in lines {
            if line.kind == .grid {
                // Dotted: short dashes, each with its side borders.
                let w = GridConstants.gridWidth, a0 = (a - w / 2).rounded()
                var c: CGFloat = 0
                while c < cross {
                    let l = min(GridConstants.gridDash, cross - c)
                    core.appendRect(rect(a0, w, c, l))
                    border.appendRect(rect(a0 - 1, 1, c, l))
                    border.appendRect(rect(a0 + w, 1, c, l))
                    c += GridConstants.gridPeriod
                }
                continue
            }
            let w: CGFloat = switch line.kind {
            case .bar: GridConstants.barWidth
            case .beat: GridConstants.beatWidth
            case .grid: GridConstants.gridWidth
            }
            let a0 = (a - w / 2).rounded()
            core.appendRect(rect(a0, w))
            border.appendRect(rect(a0 - 1, 1))
            border.appendRect(rect(a0 + w, 1))
        }
        NSColor.black.withAlphaComponent(0.5).setFill()
        border.fill()
        NSColor.white.withAlphaComponent(0.5).setFill()
        core.fill()
    }
}

/// Toolbar "Grid" control: a button showing the current value, opening a panel with the grid kind
/// and the note values.
struct GridControl: View {
    @Environment(AppState.self) private var state
    @State private var shown = false

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 6) {
            Toggle("Grid lines", isOn: $state.gridLinesShown)
                .toggleStyle(.checkbox)
                .help("Show grid lines")
            Button { shown.toggle() } label: {
                Text("Grid \(state.gridLabel)").monospacedDigit()
            }
            .help("Grid")
            .accessibilityLabel("Grid")
            .popover(isPresented: $shown, arrowEdge: .bottom) { GridPanel().padding(12) }
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
