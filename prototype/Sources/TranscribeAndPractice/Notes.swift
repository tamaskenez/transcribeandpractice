import AppKit

// MARK: Model (see the spec, "Notes")

/// A point on the beat grid: `tau` (0 ≤ tau < 1) of the way from the beat to the next beat.
struct GridLoc: Equatable {
    /// Beat id (`Beat.id`; an index in the session file).
    var beat: Int
    var tau: Rational
}

/// A note (milestone 15: a single segment, the only building block): from `start` to `end` on
/// the beat grid, the pitch going linearly from `startPitch` to `endPitch` (MIDI note numbers;
/// fractional values: between semitones).
struct Note: Equatable {
    /// Identity in memory (not stored).
    let id: Int
    var start: GridLoc, end: GridLoc
    var startPitch: Float, endPitch: Float

    init(start: GridLoc, startPitch: Float, end: GridLoc, endPitch: Float) {
        id = Note.makeID()
        self.start = start
        self.end = end
        self.startPitch = startPitch
        self.endPitch = endPitch
    }

    /// Same content (ignoring the id).
    func sameNote(as o: Note) -> Bool {
        start == o.start && end == o.end && startPitch == o.startPitch && endPitch == o.endPitch
    }

    nonisolated(unsafe) private static var lastID = 0
    private static func makeID() -> Int { lastID += 1; return lastID }
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

    /// The note's start and end positions.
    func span(_ n: Note) -> (start: Rational, end: Rational)? {
        guard let a = position(n.start), let b = position(n.end) else { return nil }
        return (a, b)
    }

    /// Beat indices the note uses: from its start's beat to the beat at or after its end.
    func usedBeats(_ n: Note) -> ClosedRange<Int>? {
        span(n).map { $0.start.floor...$0.end.ceil }
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

    // Selection (milestone 14): a set of notes by id.

    /// Click: only this note.
    func selectOnlyNote(id: Int) { selectedNotes = [id] }
    /// ⌘-click: toggles the note.
    func toggleNote(id: Int) { if selectedNotes.remove(id) == nil { selectedNotes.insert(id) } }
    func clearNoteSelection() { if !selectedNotes.isEmpty { selectedNotes = [] } }

    /// Drops selected notes that are gone.
    func pruneNoteSelection() {
        let ids = Set(notes.map(\.id))
        if !selectedNotes.isSubset(of: ids) { selectedNotes.formIntersection(ids) }
    }

    /// Indices of the selected notes, ascending.
    var selectedNoteIndices: [Int] { notes.indices.filter { selectedNotes.contains(notes[$0].id) } }

    /// Backspace: deletes the selected notes.
    func deleteSelectedNotes() {
        guard !selectedNotes.isEmpty else { return }
        let gone = selectedNotes
        selectedNotes = []
        notes.removeAll { gone.contains($0.id) }
        saveSession()
    }

    /// Adds a note unless the same one is there, and saves.
    func addNote(_ n: Note) {
        guard !notes.contains(where: { $0.sameNote(as: n) }) else { return }
        notes.append(n)
        saveSession()
    }
}

// MARK: Drawing

/// A note as drawn: the white outline's end-circle centres (the black one is offset by (+1, +1)),
/// their radius, and the note's area on whole points.
struct NoteShape {
    var note: Note
    var start: CGPoint, end: CGPoint
    var radius: CGFloat
    /// From the note's start to its end in time, across both pitches ± ½.
    var area: NSRect
    /// Length along the time axis and the cross size (one semitone).
    var length: CGFloat, width: CGFloat
    /// Shorter than wide: drawn as an ellipse in `ellipseBox`.
    var isEllipse: Bool { length < width }
    var ellipseBox: NSRect
    /// The white outline: the capsule or the ellipse.
    var outline: CGPath
    /// The geometric centres of the end circles (between the white and the black outline) and the
    /// middle: the handles.
    var handleCentres: [CGPoint] {
        let a = CGPoint(x: start.x + 0.5, y: start.y + 0.5), b = CGPoint(x: end.x + 0.5, y: end.y + 0.5)
        return [a, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), b]
    }
    /// Handles shown: three, only the middle one when shorter than 3 × its width, none when an
    /// ellipse.
    var visibleHandles: [CGPoint] {
        if isEllipse { return [] }
        if length < 3 * width { return [handleCentres[1]] }
        return handleCentres
    }
}

enum NoteDrawing {
    /// Reach (points) around a note's capsule within which the pointer hovers it.
    static let hoverReach: CGFloat = 3
    /// Opacity of a selected note's accent fill.
    static let selectedFillOpacity: CGFloat = 0.35
    /// Opacity of the selection rectangle's accent fill.
    static let bandFillOpacity: CGFloat = 0.2

    /// The hull of two circles of radius r (a capsule; a circle if they coincide).
    static func capsule(_ a: CGPoint, _ b: CGPoint, _ r: CGFloat) -> CGPath {
        let circles = CGMutablePath()
        circles.addEllipse(in: CGRect(x: a.x - r, y: a.y - r, width: 2 * r, height: 2 * r))
        let other = CGMutablePath()
        other.addEllipse(in: CGRect(x: b.x - r, y: b.y - r, width: 2 * r, height: 2 * r))
        var path: CGPath = circles.union(other)
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        if len > 0.01 {
            let nx = -dy / len * r, ny = dx / len * r
            let quad = CGMutablePath()
            quad.addLines(between: [CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny),
                                    CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)])
            quad.closeSubpath()
            path = path.union(quad)
        }
        return path
    }

    /// Distance from p to the segment a–b.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
        let t = l2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

extension WaveformNSView {
    /// Cross position (from the low edge) of a pitch's lower boundary (pitch − ½) and of its upper one.
    private func pitchEdges(_ p: Float) -> (lo: CGFloat, hi: CGFloat) {
        guard let state else { return (0, 0) }
        let k = Double(p) - Double(SpectrogramConstants.lowestNote)
        let pps = SpectrogramConstants.pointsPerSemitone
        return (CGFloat((k - state.freqBottom) * pps).rounded(), CGFloat((k + 1 - state.freqBottom) * pps).rounded())
    }

    /// A rectangle in view coordinates from an axis range and a cross range (from the low edge).
    private func viewRect(axis a0: CGFloat, _ a1: CGFloat, cross lo: CGFloat, _ hi: CGFloat) -> NSRect {
        orientation == .horizontal
            ? NSRect(x: a0, y: bounds.height - hi, width: a1 - a0, height: hi - lo)
            : NSRect(x: lo, y: a0, width: hi - lo, height: a1 - a0)
    }

    /// The white outline's circle centre for an end circle whose square (side = the cross size)
    /// starts at axis position `a`: the white outline fills the square minus its last point row
    /// and column (the black one is offset by (+1, +1)).
    private func circleCentre(axis a: CGFloat, pitch: Float) -> (CGPoint, CGFloat, CGFloat) {
        let (lo, hi) = pitchEdges(pitch)
        let h = hi - lo
        let sq = viewRect(axis: a, a + h, cross: lo, hi)
        return (CGPoint(x: sq.minX + (sq.width - 1) / 2, y: sq.minY + (sq.height - 1) / 2), (h - 1) / 2 - 0.5, h)
    }

    /// The note's shape in view coordinates (nil if its beats are gone).
    func shape(of n: Note) -> NoteShape? {
        guard let state, let audio = state.audio else { return nil }
        let g = state.beatGrid
        guard let (p0, p1) = g.span(n) else { return nil }
        let a0 = axis(ofTime: g.time(p0, sampleRate: audio.sampleRate)).rounded()
        let a1 = axis(ofTime: g.time(p1, sampleRate: audio.sampleRate)).rounded()
        let (c0, r, h) = circleCentre(axis: a0, pitch: n.startPitch)
        let (c1, _, _) = circleCentre(axis: a1 - h, pitch: n.endPitch)
        let e0 = pitchEdges(n.startPitch), e1 = pitchEdges(n.endPitch)
        let area = viewRect(axis: a0, a1, cross: min(e0.lo, e1.lo), max(e0.hi, e1.hi))
        let em = pitchEdges((n.startPitch + n.endPitch) / 2)
        let box = viewRect(axis: a0, a1, cross: em.lo, em.hi)
        let outline: CGPath
        if a1 - a0 < h {
            let e = CGMutablePath()
            e.addEllipse(in: NSRect(x: box.minX, y: box.minY, width: box.width - 1, height: box.height - 1).insetBy(dx: 0.5, dy: 0.5))
            outline = e
        } else {
            outline = NoteDrawing.capsule(c0, c1, r)
        }
        return NoteShape(note: n, start: c0, end: c1, radius: r, area: area, length: a1 - a0, width: h,
                         ellipseBox: box, outline: outline)
    }

    /// The note's bounding area.
    func rect(of n: Note) -> NSRect? { shape(of: n)?.area }

    /// The visible notes' shapes.
    func noteShapes() -> [NoteShape] {
        guard isSpectrogram, let state else { return [] }
        return state.notes.compactMap { n in shape(of: n).flatMap { $0.outline.boundingBoxOfPath.insetBy(dx: -2, dy: -2).intersects(bounds) ? $0 : nil } }
    }

    /// The note under the point: the nearest one whose capsule (or ellipse) is within reach.
    func hoveredNote(at p: CGPoint) -> NoteShape? {
        if isBandDragging { return nil }
        var best: (NoteShape, CGFloat)?
        for sh in noteShapes() {
            let d: CGFloat
            if sh.isEllipse {
                d = sh.ellipseBox.insetBy(dx: -NoteDrawing.hoverReach, dy: -NoteDrawing.hoverReach).contains(p) ? 0 : .infinity
            } else {
                let c = sh.handleCentres
                d = max(NoteDrawing.distance(p, c[0], c[2]) - sh.radius - 0.5, 0)
            }
            if d <= NoteDrawing.hoverReach, best == nil || d < best!.1 { best = (sh, d) }
        }
        return best?.0
    }

    /// The handle under the point (of the hovered note), as its centre.
    func handle(at p: CGPoint) -> CGPoint? {
        guard let sh = hoveredNote(at: p) else { return nil }
        let r = sh.width / 4
        return sh.visibleHandles.first { hypot($0.x - p.x, $0.y - p.y) <= r + 1 }
    }

    /// Each note as a black 1-point outline and a white one over it, offset by (−1, −1); no fill
    /// (selected: an accent fill and a 2-point accent outline instead of the white one). Then the
    /// note being created, and the handles of the hovered (or edited) note and of the note being
    /// created.
    func drawNotes() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let selected = state?.selectedNotes ?? []
        let accent = NSColor.controlAccentColor
        func outline(_ sh: NoteShape, selected: Bool) {
            var shift = CGAffineTransform(translationX: 1, y: 1)
            if let black = sh.outline.copy(using: &shift) {
                ctx.addPath(black); ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(1); ctx.strokePath()
            }
            if selected {
                ctx.addPath(sh.outline); ctx.setFillColor(accent.withAlphaComponent(NoteDrawing.selectedFillOpacity).cgColor); ctx.fillPath()
                ctx.addPath(sh.outline); ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(2); ctx.strokePath()
            } else {
                ctx.addPath(sh.outline); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1); ctx.strokePath()
            }
        }
        for sh in noteShapes() { outline(sh, selected: selected.contains(sh.note.id)) }
        if let created = creationShape() { outline(created, selected: false) }
        ctx.restoreGState()
        if let sh = handleNote() { drawHandles(sh.visibleHandles, diameter: sh.width / 2) }
        if let h = creationHandle() { drawHandles([h.centre], diameter: h.diameter) }
    }

    /// Handles: moving dashes circles at full opacity, with a cross (+) in each, as wide as the
    /// circle: black, then white over it offset by (−1, −1), like the note outline; on whole points.
    func drawHandles(_ centres: [CGPoint], diameter d: CGFloat) {
        let path = NSBezierPath()
        for c in centres { path.appendOval(in: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)) }
        strokeAlternating(path, opacity: 1)
        let black = NSBezierPath(), white = NSBezierPath()
        let w = d.rounded()
        for c in centres {
            // The white cross is centred half a point up-left of the handle's centre.
            let x0 = (c.x - 0.5 - w / 2).rounded(), y0 = (c.y - 0.5 - w / 2).rounded()
            let cx = (c.x - 1).rounded(), cy = (c.y - 1).rounded()
            for (path, off) in [(black, CGFloat(1)), (white, CGFloat(0))] {
                path.appendRect(NSRect(x: x0 + off, y: cy + off, width: w, height: 1))
                path.appendRect(NSRect(x: cx + off, y: y0 + off, width: 1, height: w))
            }
        }
        NSColor.black.setFill(); black.fill()
        NSColor.white.setFill(); white.fill()
    }

    /// The hovered (or edited, or created) note's outline moved 12 · log2(i) semitones higher for
    /// i = 2 … harmonics (the white outline's path; up in horizontal mode, right in vertical mode).
    func noteHarmonicOutlines() -> [CGPath] {
        guard let sh = creation != nil ? creationShape() : handleNote() else { return [] }
        return harmonicShifts().compactMap { semis in
            let d = CGFloat(semis * SpectrogramConstants.pointsPerSemitone)
            var t = orientation == .horizontal ? CGAffineTransform(translationX: 0, y: -d) : CGAffineTransform(translationX: d, y: 0)
            return sh.outline.copy(using: &t)
        }
    }

    /// Over a note (instead of the hover cell): its harmonic copies in the moving dashes style.
    func drawNoteHarmonics() {
        let path = NSBezierPath()
        for o in noteHarmonicOutlines() { path.append(NSBezierPath(cgPath: o)) }
        strokeAlternating(path)
    }

    /// Notes (ids) whose drawn capsule or ellipse (both outlines) lies inside the rectangle (view
    /// coordinates).
    func notes(inside r: NSRect) -> Set<Int> {
        Set(noteShapes().filter { sh in
            let white = sh.outline.boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5)
            return r.contains(white.union(white.offsetBy(dx: 1, dy: 1)))
        }.map(\.note.id))
    }
}
