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

/// A note segment: segment k of a note runs from point k to point k + 1 (or the end).
struct SegmentRef: Hashable { var note: Int; var segment: Int }

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

    // Selection (milestone 14): by note segment.

    /// Click: only this segment.
    func selectOnlySegment(_ r: SegmentRef) { selectedSegments = [r] }
    /// ⌘-click: toggles the segment.
    func toggleSegment(_ r: SegmentRef) { if selectedSegments.remove(r) == nil { selectedSegments.insert(r) } }
    /// Double-click: only the whole note (all its segments).
    func selectOnlyNote(id: Int) {
        guard let n = notes.first(where: { $0.id == id }) else { return }
        selectedSegments = Set(n.points.indices.map { SegmentRef(note: id, segment: $0) })
    }
    func clearNoteSelection() { if !selectedSegments.isEmpty { selectedSegments = [] } }

    /// Drops selected segments whose note or segment is gone.
    func pruneSegmentSelection() {
        let counts = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.points.count) })
        let kept = selectedSegments.filter { (counts[$0.note] ?? 0) > $0.segment }
        if kept != selectedSegments { selectedSegments = kept }
    }

    /// The selected segments as (note index, segment index), sorted.
    var selectedSegmentList: [(Int, Int)] {
        notes.enumerated().flatMap { i, n in
            n.points.indices.filter { selectedSegments.contains(SegmentRef(note: n.id, segment: $0)) }.map { (i, $0) }
        }
    }

    /// Backspace: deletes the selected segments. Each remaining run of consecutive segments of a
    /// note becomes a note of its own: it ends at the location of the point after the run (with
    /// that point's pre-pitch; the note's end for the last run); a run that started at an inner
    /// point gets pre = post there (no pre → post capsule at its new start).
    func deleteSelectedSegments() {
        guard !selectedSegments.isEmpty else { return }
        var out: [NoteTrajectory] = []
        for n in notes {
            let gone = Set(n.points.indices.filter { selectedSegments.contains(SegmentRef(note: n.id, segment: $0)) })
            if gone.isEmpty { out.append(n); continue }
            var k = 0
            while k < n.points.count {
                if gone.contains(k) { k += 1; continue }
                var m = k
                while m + 1 < n.points.count, !gone.contains(m + 1) { m += 1 }
                var pts = Array(n.points[k...m])
                if k > 0, gone.contains(k - 1) { pts[0].pre = pts[0].post }
                let last = m + 1 < n.points.count
                let end = last ? n.points[m + 1].loc : n.end
                let endPitch = last ? n.points[m + 1].pre : n.endPitch
                out.append(k == 0 && m == n.points.count - 1 ? n : NoteTrajectory(points: pts, endPitch: endPitch, end: end))
                k = m + 1
            }
        }
        selectedSegments = []
        notes = out
        saveSession()
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

// MARK: Drawing (milestone 14: segments, pre → post capsules, handles)

/// One segment of a note as drawn: the white outline's end-circle centres (the black one is
/// offset by (+1, +1)), their radius, and the segment's area on whole points.
struct NoteSegmentShape {
    var start: CGPoint, end: CGPoint
    var radius: CGFloat
    /// From the segment's start to its end in time, across both end pitches ± ½.
    var area: NSRect
    /// Length along the time axis and the cross size (one semitone).
    var length: CGFloat, width: CGFloat
    /// Shorter than wide: drawn as an ellipse in `ellipseBox` (no pre → post capsules next to it).
    var isEllipse: Bool { length < width }
    var ellipseBox: NSRect
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

/// A note as drawn: its segments and the pre → post capsules (pairs of white centres).
struct NoteShape {
    var note: NoteTrajectory
    var segments: [NoteSegmentShape]
    var transitions: [(CGPoint, CGPoint)]
    var radius: CGFloat
    /// The white outline (the union of all capsules and ellipses).
    var outline: CGPath
    var bounds: NSRect { segments.map(\.area).reduce(segments[0].area) { $0.union($1) } }
}

enum NoteDrawing {
    /// Reach (points) around a segment's capsule within which the pointer hovers it.
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
    func shape(of n: NoteTrajectory) -> NoteShape? {
        guard let state, let audio = state.audio else { return nil }
        let g = state.beatGrid
        var locs: [Rational] = []
        for p in n.points { guard let x = g.position(p.loc) else { return nil }; locs.append(x) }
        guard let endPos = g.position(n.end) else { return nil }
        locs.append(endPos)
        let axes = locs.map { axis(ofTime: g.time($0, sampleRate: audio.sampleRate)).rounded() }
        var segments: [NoteSegmentShape] = []
        var radius: CGFloat = 0
        for k in 0..<n.points.count {
            let p0 = n.points[k].post, p1 = k + 1 < n.points.count ? n.points[k + 1].pre : n.endPitch
            let a0 = axes[k], a1 = axes[k + 1]
            let (c0, r, h) = circleCentre(axis: a0, pitch: p0)
            let (c1, _, _) = circleCentre(axis: a1 - h, pitch: p1)
            radius = r
            let e0 = pitchEdges(p0), e1 = pitchEdges(p1)
            let area = viewRect(axis: a0, a1, cross: min(e0.lo, e1.lo), max(e0.hi, e1.hi))
            let em = pitchEdges((p0 + p1) / 2)
            segments.append(NoteSegmentShape(start: c0, end: c1, radius: r, area: area, length: a1 - a0, width: h,
                                             ellipseBox: viewRect(axis: a0, a1, cross: em.lo, em.hi)))
        }
        // Pre → post capsules: at an inner point between the neighbouring segments' circles; at
        // the first point across it, from a circle at the pre-pitch just before it.
        var transitions: [(CGPoint, CGPoint)] = []
        for (k, p) in n.points.enumerated() where p.pre != p.post && !segments[k].isEllipse {
            if k == 0 {
                let h = segments[0].width
                let (c, _, _) = circleCentre(axis: axes[0] - h, pitch: p.pre)
                transitions.append((c, segments[0].start))
            } else if !segments[k - 1].isEllipse {
                transitions.append((segments[k - 1].end, segments[k].start))
            }
        }
        var outline = CGMutablePath() as CGPath
        var first = true
        func add(_ path: CGPath) { outline = first ? path : outline.union(path); first = false }
        for sg in segments {
            if sg.isEllipse {
                let b = sg.ellipseBox
                let e = CGMutablePath()
                e.addEllipse(in: NSRect(x: b.minX, y: b.minY, width: b.width - 1, height: b.height - 1).insetBy(dx: 0.5, dy: 0.5))
                add(e)
            } else {
                add(NoteDrawing.capsule(sg.start, sg.end, sg.radius))
            }
        }
        for (a, b) in transitions { add(NoteDrawing.capsule(a, b, radius)) }
        return NoteShape(note: n, segments: segments, transitions: transitions, radius: radius, outline: outline)
    }

    /// A segment's own capsule (or ellipse), as the white outline's path.
    func segmentPath(_ sg: NoteSegmentShape) -> CGPath {
        if sg.isEllipse {
            let b = sg.ellipseBox
            let e = CGMutablePath()
            e.addEllipse(in: NSRect(x: b.minX, y: b.minY, width: b.width - 1, height: b.height - 1).insetBy(dx: 0.5, dy: 0.5))
            return e
        }
        return NoteDrawing.capsule(sg.start, sg.end, sg.radius)
    }

    /// The note's bounding area (all its segments).
    func rect(of n: NoteTrajectory) -> NSRect? { shape(of: n)?.bounds }

    /// The visible notes' shapes.
    func noteShapes() -> [NoteShape] {
        guard isSpectrogram, let state else { return [] }
        return state.notes.compactMap { n in shape(of: n).flatMap { $0.outline.boundingBoxOfPath.insetBy(dx: -2, dy: -2).intersects(bounds) ? $0 : nil } }
    }

    /// The segment under the point: the nearest one whose capsule (or ellipse) is within reach.
    func hoveredSegment(at p: CGPoint) -> (note: NoteShape, segment: Int)? {
        if isBandDragging { return nil }
        var best: (NoteShape, Int, CGFloat)?
        for sh in noteShapes() {
            for (k, sg) in sh.segments.enumerated() {
                let c = sg.handleCentres
                let d: CGFloat
                if sg.isEllipse {
                    let b = sg.ellipseBox.insetBy(dx: -NoteDrawing.hoverReach, dy: -NoteDrawing.hoverReach)
                    d = b.contains(p) ? 0 : .infinity
                } else {
                    d = max(NoteDrawing.distance(p, c[0], c[2]) - sg.radius - 0.5, 0)
                }
                if d <= NoteDrawing.hoverReach, best == nil || d < best!.2 { best = (sh, k, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// The handle under the point (of the hovered segment), as its centre.
    func handle(at p: CGPoint) -> CGPoint? {
        guard let (sh, k) = hoveredSegment(at: p) else { return nil }
        let r = sh.segments[k].width / 4
        return sh.segments[k].visibleHandles.first { hypot($0.x - p.x, $0.y - p.y) <= r + 1 }
    }

    /// Each note: the union of its capsules as a black 1-point outline and a white one over it,
    /// offset by (−1, −1); no fill. Then the hovered segment's handles (moving dashes circles at
    /// full opacity, half the capsule's diameter, with a black-and-white cross as wide).
    func drawNotes() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setLineWidth(1)
        let selected = state?.selectedSegments ?? []
        let accent = NSColor.controlAccentColor
        for sh in noteShapes() {
            let sel = sh.segments.indices.filter { selected.contains(SegmentRef(note: sh.note.id, segment: $0)) }
            let whole = sel.count == sh.segments.count
            var shift = CGAffineTransform(translationX: 1, y: 1)
            if let black = sh.outline.copy(using: &shift) {
                ctx.addPath(black); ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(1); ctx.strokePath()
            }
            ctx.addPath(sh.outline); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1); ctx.strokePath()
            // Selected: a translucent accent fill and a 2-point accent outline: around the whole
            // note when all its segments are selected, else around each selected segment.
            let paths = whole ? [sh.outline] : sel.map { segmentPath(sh.segments[$0]) }
            for p in paths {
                ctx.addPath(p); ctx.setFillColor(accent.withAlphaComponent(NoteDrawing.selectedFillOpacity).cgColor); ctx.fillPath()
                ctx.addPath(p); ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(2); ctx.strokePath()
            }
        }
        ctx.restoreGState()
        if let p = hoverPoint, let (sh, k) = hoveredSegment(at: p) {
            let sg = sh.segments[k], d = sg.width / 2
            let path = NSBezierPath()
            for c in sg.visibleHandles { path.appendOval(in: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)) }
            strokeAlternating(path, opacity: 1)
            // A cross (+) in each, as wide as the circle: black, then white over it offset by
            // (−1, −1), like the note outline; on whole points.
            let black = NSBezierPath(), white = NSBezierPath()
            let w = d.rounded()
            for c in sg.visibleHandles {
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
    }

    /// The hovered note's outline moved 12 · log2(i) semitones higher for i = 2 … harmonics (the
    /// white outline's path; up in horizontal mode, right in vertical mode).
    func noteHarmonicOutlines() -> [CGPath] {
        guard let p = hoverPoint, let (sh, _) = hoveredSegment(at: p) else { return [] }
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

    /// Segments whose drawn capsule (or ellipse; both outlines) lies inside the rectangle (view
    /// coordinates). Pre → post capsules don't count.
    func segments(inside r: NSRect) -> [SegmentRef] {
        noteShapes().flatMap { sh in
            sh.segments.indices.filter { k in
                let white = segmentPath(sh.segments[k]).boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5)
                return r.contains(white.union(white.offsetBy(dx: 1, dy: 1)))
            }.map { SegmentRef(note: sh.note.id, segment: $0) }
        }
    }
}
