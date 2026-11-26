import AppKit

// MARK: Model (see the spec, "Notes")

/// A point on the beat grid: `tau` (0 ≤ tau < 1) of the way from the beat to the next beat.
struct GridLoc: Equatable {
    /// Beat id (`Beat.id`; an index in the session file).
    var beat: Int
    var tau: Rational
}

/// A point of a note trajectory: the pitch changes from `pre` to `post` around the grid location.
/// Pitches are MIDI note numbers (fractional values: between semitones).
struct NotePoint: Equatable {
    var pre: Float
    var post: Float
    var loc: GridLoc
}

/// A played note: one or more segments between grid locations. The pitch is interpolated
/// linearly (in MIDI note numbers) from a point's `post` to the next point's `pre` (or
/// `endPitch`); around each point it changes from `pre` to `post` within the transition window
/// (`NoteConstants`).
struct NoteTrajectory: Equatable {
    /// Identity in memory (not stored).
    let id: Int
    /// At least one; strictly increasing locations.
    var points: [NotePoint]
    var endPitch: Float
    var end: GridLoc

    init(points: [NotePoint], endPitch: Float, end: GridLoc) {
        id = NoteTrajectory.makeID()
        self.points = points
        self.endPitch = endPitch
        self.end = end
    }

    /// A single segment at a constant pitch (what a click places in this milestone).
    init(pitch: Float, from start: GridLoc, to end: GridLoc) {
        self.init(points: [NotePoint(pre: pitch, post: pitch, loc: start)], endPitch: pitch, end: end)
    }

    /// Same content (ignoring the id).
    func sameNote(as o: NoteTrajectory) -> Bool { points == o.points && endPitch == o.endPitch && end == o.end }

    nonisolated(unsafe) private static var lastID = 0
    private static func makeID() -> Int { lastID += 1; return lastID }
}

enum NoteConstants {
    /// The longest pre → post transition, in beats: beat_note / 8 (one eighth of a beat). It is
    /// also limited to an eighth of the preceding segment; the first point has no preceding
    /// segment, so its transition lies before the point (the note starts sounding earlier).
    static let maxTransitionBeats = Rational(1, 8)
}

/// Beat positions: beat index + tau (exact).
struct BeatGrid {
    let beats: [Beat]
    let index: [Int: Int]

    init(_ beats: [Beat]) {
        self.beats = beats
        index = Dictionary(uniqueKeysWithValues: beats.enumerated().map { ($1.id, $0) })
    }

    /// The location's position (beat index + tau), nil if its beat (or the next one it needs) is gone.
    func position(_ l: GridLoc) -> Rational? {
        guard let i = index[l.beat], l.tau == Rational(0, 1) || i + 1 < beats.count else { return nil }
        return Rational(i, 1) + l.tau
    }

    /// The location at a position (0 ≤ p ≤ last beat index).
    func loc(at p: Rational) -> GridLoc {
        let i = min(p.floor, beats.count - 1)
        return GridLoc(beat: beats[i].id, tau: p - Rational(i, 1))
    }

    /// Seconds at a position (linear inside a beat interval).
    func time(_ p: Rational, sampleRate fs: Double) -> Double {
        let i = min(p.floor, beats.count - 1)
        let t0 = Double(beats[i].sample) / fs
        let frac = (p - Rational(i, 1)).doubleValue
        guard frac > 0, i + 1 < beats.count else { return t0 }
        return t0 + frac * (Double(beats[i + 1].sample) / fs - t0)
    }

    /// The trajectory's start and end positions.
    func span(_ n: NoteTrajectory) -> (start: Rational, end: Rational)? {
        guard let a = n.points.first.flatMap({ position($0.loc) }), let b = position(n.end) else { return nil }
        return (a, b)
    }

    /// Beat indices the trajectory uses: from its first point's beat to the beat at or after its end.
    func usedBeats(_ n: NoteTrajectory) -> ClosedRange<Int>? {
        span(n).map { $0.start.floor...$0.end.ceil }
    }

    /// The pitch curve as breakpoints (position in beats, MIDI pitch), linear between them; see
    /// `NoteTrajectory`. Transitions with equal pre and post pitch are left out.
    func pitchCurve(_ n: NoteTrajectory) -> [(pos: Double, pitch: Float)] {
        let pos = n.points.map { position($0.loc)?.doubleValue }
        guard let endPos = position(n.end)?.doubleValue, !pos.contains(where: { $0 == nil }) else { return [] }
        let x = pos.map { $0! }
        let maxT = NoteConstants.maxTransitionBeats.doubleValue
        var out: [(Double, Float)] = []
        for (i, p) in n.points.enumerated() {
            if p.pre != p.post {
                let d = i == 0 ? maxT : min(maxT, (x[i] - x[i - 1]) / 8)
                out.append((x[i] - d, p.pre))
            }
            out.append((x[i], p.post))
        }
        out.append((endPos, n.endPitch))
        return out
    }
}

// MARK: Editing

extension AppState {
    var beatGrid: BeatGrid { BeatGrid(beats) }

    /// Beat indices that notes use (can't be deleted; no beat can be inserted between them).
    var noteBeatRanges: [ClosedRange<Int>] {
        let g = beatGrid
        return notes.compactMap { g.usedBeats($0) }
    }

    /// Whether deleting these beat indices would cut a note.
    func beatsUsedByNotes(_ indices: [Int]) -> Bool {
        let ranges = noteBeatRanges
        return indices.contains { i in ranges.contains { $0.contains(i) } }
    }

    /// Whether a new beat at `sample` would fall inside a note's beats.
    func insertionCutsNote(at sample: Int) -> Bool {
        noteBeatRanges.contains { r in
            r.lowerBound < r.upperBound && beats[r.lowerBound].sample < sample && sample < beats[r.upperBound].sample
        }
    }

    /// Whether new beats in the gap after beat index `i` would fall inside a note's beats.
    func gapUsedByNotes(after i: Int) -> Bool {
        noteBeatRanges.contains { $0.lowerBound <= i && i + 1 <= $0.upperBound }
    }

    /// Click on the spectrogram: a single-segment note in the grid cell (none if the same note
    /// is already there).
    func placeNote(in cell: GridCell) {
        let g = beatGrid
        let n = NoteTrajectory(pitch: Float(cell.note), from: g.loc(at: cell.startPos), to: g.loc(at: cell.endPos))
        guard cell.startPos < cell.endPos, !notes.contains(where: { $0.sameNote(as: n) }) else { return }
        notes.append(n)
        saveSession()
    }
}

// MARK: Drawing

extension WaveformNSView {
    /// The note's area on whole points: from its start to its end in time and from pitch − ½ to
    /// pitch + ½ (the first point's pitch; notes have a constant pitch in this milestone). The
    /// edges are rounded, not centred, so the areas of adjacent notes touch without overlapping.
    func rect(of n: NoteTrajectory) -> NSRect? {
        guard let state, let audio = state.audio, let p = n.points.first else { return nil }
        let g = state.beatGrid
        guard let (s, e) = g.span(n) else { return nil }
        let a0 = axis(ofTime: g.time(s, sampleRate: audio.sampleRate)).rounded()
        let a1 = axis(ofTime: g.time(e, sampleRate: audio.sampleRate)).rounded()
        // Semitone positions are counted from A0 − ½, so note m spans m − lowest … m − lowest + 1.
        let k = Double(p.post) - Double(SpectrogramConstants.lowestNote)
        let lo = CGFloat((k - state.freqBottom) * SpectrogramConstants.pointsPerSemitone).rounded()
        let hi = CGFloat((k + 1 - state.freqBottom) * SpectrogramConstants.pointsPerSemitone).rounded()
        return orientation == .horizontal
            ? NSRect(x: a0, y: bounds.height - hi, width: a1 - a0, height: hi - lo)
            : NSRect(x: lo, y: a0, width: hi - lo, height: a1 - a0)
    }

    /// The visible notes' areas.
    func noteRects() -> [(note: NoteTrajectory, rect: NSRect)] {
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
