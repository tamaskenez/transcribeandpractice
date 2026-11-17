import AppKit
import SwiftUI

/// Polyline of the mono signal over the visible range, in pane coordinates (top-left origin).
/// A pane with time-axis length L has L+1 axis positions; position i is at time
/// start + i·(end−start)/L, i.e. sample position time·sampleRate, linearly interpolated.
/// Positions outside the file (sample position < 0 or > frames−1) get no point.
/// Amplitude ±1.0 maps to the pane edges, 0 to the middle; positive is up (horizontal) or right
/// (vertical).
func waveformPoints(mono: [Float], sampleRate: Double, start: Double, end: Double,
                    size: CGSize, orientation: TimeOrientation) -> [CGPoint] {
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
        let v = CGFloat(mono[i0] * (1 - f) + mono[i1] * f)
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
    }
    private var drag: Drag?
    private var pressPoint: CGPoint = .zero
    private var dragged = false

    override var isFlipped: Bool { true }

    var orientation: TimeOrientation { state?.orientation ?? .horizontal }
    private var timeLength: CGFloat { orientation == .horizontal ? bounds.width : bounds.height }

    func points() -> [CGPoint] {
        guard let state, let audio = state.audio else { return [] }
        return waveformPoints(mono: audio.mono, sampleRate: audio.sampleRate, start: state.viewStart,
                              end: state.viewEnd, size: bounds.size, orientation: orientation)
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

        let points = points()
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for p in points.dropFirst() { path.line(to: p) }
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        } else {
            drag = .select(anchor: t, extend: false)
        }
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
        if hypot(p.x - pressPoint.x, p.y - pressPoint.y) >= 2 { dragged = true }
        switch drag {
        case let .select(anchor, extend):
            if dragged || extend { state.select(anchor, time(atAxis: clampedAxis(p))) }
        case let .pan(grabbed):
            guard timeLength > 0 else { return }
            let start = grabbed - Double(axisPosition(p) / timeLength) * state.viewLength
            state.setView(start: start, end: start + state.viewLength)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let state, let drag else { return }
        dragTo(location(event))
        if case let .select(_, extend) = drag, !dragged, !extend { state.selection = nil }
        self.drag = nil
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
        if event.modifierFlags.contains(.command) {
            let d = dy != 0 ? dy : dx
            state.zoom(by: exp(Double(d) * 0.01), anchor: time(atAxis: clampedAxis(location(event))))
        } else {
            // Content follows the scroll: a positive delta brings earlier times into view.
            let d = orientation == .horizontal ? dx + dy : dy
            state.pan(by: -Double(d / timeLength) * state.viewLength)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let state, state.audio != nil else { return }
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
        _ = (state.audio?.mono.count, state.orientation, state.viewStart, state.viewEnd, state.selection)
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

    @objc func scrolled(_ sender: NSScroller) {
        guard let state else { return }
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
        _ = (state.audio?.duration, state.viewStart, state.viewEnd)
        view.update()
    }
}
