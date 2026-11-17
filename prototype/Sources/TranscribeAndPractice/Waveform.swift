import AppKit
import SwiftUI

/// Polyline of the mono signal over the visible range, in pane coordinates (top-left origin).
/// A pane with time-axis length L has L+1 axis positions; position i is at time
/// start + i·(end−start)/L, i.e. sample position time·sampleRate, linearly interpolated.
/// Positions outside the file (sample position < 0 or > frames−1) get no point.
/// Values are multiplied by `gain` (amplitude zoom); amplitude ±1.0 then maps to the pane edges,
/// 0 to the middle; positive is up (horizontal) or right (vertical). Points beyond the pane edges
/// are kept (drawing clips them).
func waveformPoints(mono: [Float], sampleRate: Double, start: Double, end: Double,
                    size: CGSize, orientation: TimeOrientation, gain: Double = 1) -> [CGPoint] {
    let frames = mono.count
    let length = orientation == .horizontal ? size.width : size.height
    let cross = orientation == .horizontal ? size.height : size.width
    guard frames > 0, length >= 1, cross > 0, end > start else { return [] }
    let n = Int(length) + 1
    let secondsPerPoint = (end - start) / Double(n - 1)
    let last = Double(frames - 1)
    var points: [CGPoint] = []
    points.reserveCapacity(n)
    for i in 0..<n {
        let pos = (start + Double(i) * secondsPerPoint) * sampleRate
        guard pos >= 0, pos <= last else { continue }
        let i0 = Int(pos)
        let i1 = min(i0 + 1, frames - 1)
        let f = Float(pos - Double(i0))
        let v = CGFloat(Double(mono[i0] * (1 - f) + mono[i1] * f) * gain)
        let t = CGFloat(i) * length / CGFloat(n - 1)
        points.append(orientation == .horizontal
                      ? CGPoint(x: t, y: cross / 2 * (1 - v))
                      : CGPoint(x: cross / 2 * (1 + v), y: t))
    }
    return points
}

/// Waveform pane (navigator or main). Handles zoom, pan and selection input; all of it acts on
/// the shared visible range and selection in AppState.
final class WaveformNSView: NSView {
    /// Pane name, for the state dump.
    var name = ""
    var state: AppState?
    var background: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }

    private enum Drag {
        case select(anchor: Double, extend: Bool)
        case pan(grabbedTime: Double)
        /// Moving the grabbed lines (a selection edge, the playhead, the last start) together:
        /// `anchor` is the other selection edge if an edge is grabbed; `offset` = line time −
        /// press time.
        case lines(Grab, anchor: Double?, offset: Double)
        /// Moving the whole selection.
        case move(original: ClosedRange<Double>, pressTime: Double)
    }

    /// Lines grabbed by a press: the nearest one within the tolerance, plus the other lines at
    /// the same time (within one sample). At most one selection edge.
    struct Grab: Equatable {
        var startEdge = false, endEdge = false, playhead = false, lastStart = false
        var time: Double = 0
        var edge: Bool { startEdge || endEdge }
    }
    /// What a plain press at a point would do; also decides the cursor.
    private enum Hover: Equatable { case none, lines(Grab), inside }
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

    func points() -> [CGPoint] {
        guard let state, let audio = state.audio else { return [] }
        return waveformPoints(mono: audio.mono, sampleRate: audio.sampleRate, start: state.viewStart,
                              end: state.viewEnd, size: bounds.size, orientation: orientation,
                              gain: state.amplitudeGain)
    }

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

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        let horizontal = orientation == .horizontal

        if let sel = state?.selection {
            let a = max(axis(ofTime: sel.lowerBound), 0), b = min(axis(ofTime: sel.upperBound), timeLength)
            if b > a {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                (horizontal ? NSRect(x: a, y: 0, width: b - a, height: bounds.height)
                            : NSRect(x: 0, y: a, width: bounds.width, height: b - a)).fill()
            }
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
        let points = points()
        guard let first = points.first else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).setClip() // amplitude zoom can push the polyline past the edges
        let path = NSBezierPath()
        path.move(to: first)
        for p in points.dropFirst() { path.line(to: p) }
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1
        path.stroke()
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
        if case .move = drag {
            (cursor, name) = (.closedHand, "closedHand")
        } else if case .lines = drag {
            (cursor, name) = orientation == .horizontal ? (.columnResize, "columnResize") : (.rowResize, "rowResize")
        } else if drag != nil || !flags.intersection([.option, .shift, .command]).isEmpty {
            (cursor, name) = (.arrow, "arrow")
        } else {
            switch hover(at: p) {
            case .lines:
                (cursor, name) = orientation == .horizontal ? (.columnResize, "columnResize") : (.rowResize, "rowResize")
            case .inside: (cursor, name) = (.openHand, "openHand")
            case .none: (cursor, name) = (.arrow, "arrow")
            }
        }
        cursor.set()
        cursorName = name
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: location(event), flags: event.modifierFlags) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: location(event), flags: event.modifierFlags) }
    override func mouseExited(with event: NSEvent) { if drag == nil { NSCursor.arrow.set(); cursorName = "arrow" } }
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
            drag = .pan(grabbedTime: time(atAxis: axisPosition(p)))
        } else if event.modifierFlags.contains(.shift), let sel = state.selection {
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
        drag = .pan(grabbedTime: time(atAxis: axisPosition(location(event))))
    }

    override func mouseDragged(with event: NSEvent) { dragTo(location(event)) }
    override func otherMouseDragged(with event: NSEvent) { dragTo(location(event)) }

    private func clampedAxis(_ p: CGPoint) -> CGFloat { min(max(axisPosition(p), 0), timeLength) }

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
        }
        switch drag {
        case let .select(anchor, extend):
            if dragged || extend { state.select(anchor, time(atAxis: clampedAxis(p))) }
            if dragged && !extend { state.newSelectionChanged() }
        case let .pan(grabbed):
            guard timeLength > 0 else { return }
            let start = grabbed - Double(axisPosition(p) / timeLength) * state.viewLength
            state.setView(start: start, end: start + state.viewLength)
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
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let state, let drag else { return }
        let p = location(event)
        dragTo(p)
        // A click without a drag clears the selection (also on its edges or inside it).
        state.player.core.setSelectionDragging(false)
        let clicked = time(atAxis: axisPosition(p))
        switch drag {
        case let .select(_, extend): if !dragged && !extend { state.clickedToClear(at: clicked) }
        case .lines, .move: if !dragged { state.clickedToClear(at: clicked) }
        case .pan: break
        }
        self.drag = nil
        updateCursor(at: p, flags: event.modifierFlags)
    }

    override func otherMouseUp(with event: NSEvent) {
        if case .pan = drag { dragTo(location(event)) }
        drag = nil
    }

    // MARK: Scroll and pinch

    override func scrollWheel(with event: NSEvent) {
        guard let state, state.audio != nil, timeLength > 0 else { return }
        // Line-based wheels report small deltas; scale them to roughly 10 points per line.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX * scale, dy = event.scrollingDeltaY * scale
        state.manualViewChange()
        if event.modifierFlags.contains(.command) {
            // Scrolling along the time axis zooms time; across it, amplitude. Positive zooms in.
            let (dTime, dAmp) = orientation == .horizontal ? (dx, dy) : (dy, dx)
            if dTime != 0 {
                state.zoom(by: exp(Double(dTime) * 0.01), anchor: time(atAxis: clampedAxis(location(event))))
            }
            if dAmp != 0 { state.zoomAmplitude(by: exp(Double(dAmp) * 0.01)) }
        } else {
            // Content follows the scroll: a positive delta brings earlier times into view.
            let d = orientation == .horizontal ? dx + dy : dy
            state.pan(by: -Double(d / timeLength) * state.viewLength)
        }
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

    func makeNSView(context: Context) -> WaveformNSView { WaveformNSView() }

    func updateNSView(_ view: WaveformNSView, context: Context) {
        view.name = name
        view.state = state
        view.background = background
        // Read the observed properties here so SwiftUI calls this again when they change.
        _ = (state.audio?.mono.count, state.orientation, state.viewStart, state.viewEnd, state.selection,
             state.amplitudeZoomDB, state.playhead, state.lastStart, state.isPlaying)
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
        case .decrementPage: state.pan(by: -state.viewLength)
        case .incrementPage: state.pan(by: state.viewLength)
        default:
            let start = lo + doubleValue * rest
            state.setView(start: start, end: start + state.viewLength)
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
