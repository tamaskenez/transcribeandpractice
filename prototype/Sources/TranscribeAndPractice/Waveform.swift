import AppKit
import SwiftUI

/// Polyline of the mono signal over the whole file, in pane coordinates (top-left origin).
/// Time-axis position i of n maps to sample position i·(frames−1)/(n−1), linearly interpolated.
/// Amplitude ±1.0 maps to the pane edges, 0 to the middle; positive is up (horizontal) or right
/// (vertical).
func waveformPoints(mono: [Float], size: CGSize, orientation: TimeOrientation) -> [CGPoint] {
    let frames = mono.count
    let length = orientation == .horizontal ? size.width : size.height
    let cross = orientation == .horizontal ? size.height : size.width
    guard frames > 0, length >= 1, cross > 0 else { return [] }
    let n = Int(length) + 1
    let step = frames > 1 ? Double(frames - 1) / Double(n - 1) : 0
    var points: [CGPoint] = []
    points.reserveCapacity(n)
    for i in 0..<n {
        let pos = Double(i) * step
        let i0 = min(Int(pos), frames - 1)
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

final class WaveformNSView: NSView {
    /// Pane name, for the state dump.
    var name = ""
    var mono: [Float] = [] { didSet { needsDisplay = true } }
    var orientation: TimeOrientation = .horizontal { didSet { needsDisplay = true } }
    var background: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    // No mouse interaction yet; let the divider's drag area (which overlaps the panes) get events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        // Zero line.
        let zero = NSBezierPath()
        if orientation == .horizontal {
            zero.move(to: CGPoint(x: 0, y: bounds.midY)); zero.line(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        } else {
            zero.move(to: CGPoint(x: bounds.midX, y: 0)); zero.line(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        }
        NSColor.separatorColor.setStroke()
        zero.lineWidth = 1
        zero.stroke()

        let points = waveformPoints(mono: mono, size: bounds.size, orientation: orientation)
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for p in points.dropFirst() { path.line(to: p) }
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

struct WaveformView: NSViewRepresentable {
    let name: String
    let mono: [Float]
    let orientation: TimeOrientation
    let background: NSColor

    func makeNSView(context: Context) -> WaveformNSView { WaveformNSView() }

    func updateNSView(_ view: WaveformNSView, context: Context) {
        // Arrays share storage when copied, so comparing the buffers' addresses avoids an O(n) compare.
        if !sameStorage(view.mono, mono) { view.mono = mono }
        view.name = name
        view.orientation = orientation
        view.background = background
    }
}

private func sameStorage(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
}
