import AppKit

/// A placed note (milestone 13, experimental; not saved yet): a MIDI note over a sample range.
struct Note: Equatable {
    var midi: Int
    /// First sample and the sample where it ends (exclusive), from the grid cell it was placed in.
    var start: Int, end: Int
}

extension AppState {
    /// Click on the spectrogram: a note in the grid cell (none if the same note is already there).
    func placeNote(in cell: GridCell) {
        guard let audio else { return }
        let n = Note(midi: cell.note, start: roundSample(cell.start * audio.sampleRate),
                     end: roundSample(cell.end * audio.sampleRate))
        guard n.end > n.start, !notes.contains(n) else { return }
        notes.append(n)
    }
}

extension WaveformNSView {
    /// The note's area on whole points: from its start to its end in time and from its low to its
    /// high boundary (note ∓ ½) in pitch. The edges are rounded, not centred, so the areas of
    /// adjacent notes touch without overlapping.
    func rect(of n: Note) -> NSRect? {
        guard let state, let audio = state.audio else { return nil }
        let a0 = axis(ofTime: Double(n.start) / audio.sampleRate).rounded()
        let a1 = axis(ofTime: Double(n.end) / audio.sampleRate).rounded()
        let k = Double(n.midi - SpectrogramConstants.lowestNote)
        let lo = CGFloat((k - state.freqBottom) * SpectrogramConstants.pointsPerSemitone).rounded()
        let hi = CGFloat((k + 1 - state.freqBottom) * SpectrogramConstants.pointsPerSemitone).rounded()
        return orientation == .horizontal
            ? NSRect(x: a0, y: bounds.height - hi, width: a1 - a0, height: hi - lo)
            : NSRect(x: lo, y: a0, width: hi - lo, height: a1 - a0)
    }

    /// The visible notes' areas.
    func noteRects() -> [(note: Note, rect: NSRect)] {
        guard isSpectrogram, let state else { return [] }
        return state.notes.compactMap { n in rect(of: n).flatMap { $0.intersects(bounds) ? (n, $0) : nil } }
    }

    /// Each note: a capsule along the time axis (semicircles of the note's height at both ends;
    /// an ellipse when it is shorter than that), as a black 1-point outline and a white one
    /// over it, offset by (−1, −1). Each is one point smaller than the note's area, so the two
    /// together fill it exactly.
    func drawNotes() {
        let horizontal = orientation == .horizontal
        let white = NSBezierPath(), black = NSBezierPath()
        for (_, r) in noteRects() where r.width >= 2 && r.height >= 2 {
            let box = NSRect(x: r.minX, y: r.minY, width: r.width - 1, height: r.height - 1)
            black.append(Self.capsule(box.offsetBy(dx: 1, dy: 1), horizontal: horizontal))
            white.append(Self.capsule(box, horizontal: horizontal))
        }
        for (path, color) in [(black, NSColor.black), (white, NSColor.white)] {
            path.lineWidth = 1
            color.setStroke()
            path.stroke()
        }
    }

    /// A capsule filling `box` (the 1-point line inside it), rounded at the ends of the time axis.
    static func capsule(_ box: NSRect, horizontal: Bool) -> NSBezierPath {
        let q = box.insetBy(dx: 0.5, dy: 0.5)
        let length = horizontal ? q.width : q.height, d = horizontal ? q.height : q.width
        if length < d { return NSBezierPath(ovalIn: q) }
        return NSBezierPath(roundedRect: q, xRadius: d / 2, yRadius: d / 2)
    }
}
