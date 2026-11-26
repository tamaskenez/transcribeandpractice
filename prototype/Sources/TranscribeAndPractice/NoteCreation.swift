import AppKit

// Milestone 15: creating notes by dragging (with the hold timer) and editing pitches with the
// handles. See the spec, "Creating notes by dragging" and "Editing pitches with the handles".

enum NoteCreationConstants {
    /// How long the pointer rests on a handle until the hold timer acts (seconds).
    static let holdSeconds = 1.0
    /// The hold timer's pie: diameter and offset of its centre from the pointer tip (screen
    /// terms: right and down), points.
    static let pieDiameter: CGFloat = 14
    static let pieOffset: CGFloat = 16
    /// Redraw rate of the pie while the timer runs.
    static let pieInterval = 1.0 / 60
}

/// The note being created by a drag: the finished points (each the start of a finalised segment)
/// and the current segment, from `current` (at `startPos`) to `endPos` at `endPitch`.
struct NoteCreation {
    var finished: [NotePoint] = []
    var current: NotePoint
    var startPos: Rational, endPos: Rational
    var endPitch: Float
    /// The current segment's first point is fixed (its post-pitch stays; the end follows the
    /// pointer's note); otherwise its post-pitch follows the pointer (a flat segment).
    var firstFixed = true
    /// The pointer was over a valid cell at the last update (a release keeps the current segment).
    var valid = true
    /// The note was added (the beats ran out); the rest of the drag does nothing.
    var complete = false
    /// The pointer entered the drawn handle at this time: the hold timer runs.
    var holdStart: Date?
    /// The handle may start the timer; false while the pointer stays on a handle that appeared
    /// under it.
    var armed = true
    /// The last pointer position (view coordinates).
    var pointer: CGPoint

    /// The note so far, with or without the current segment (nil: nothing yet).
    func trajectory(_ g: BeatGrid, withCurrent: Bool) -> NoteTrajectory? {
        if withCurrent {
            return NoteTrajectory(points: finished + [current], endPitch: endPitch, end: g.loc(at: endPos))
        }
        guard !finished.isEmpty else { return nil }
        return NoteTrajectory(points: finished, endPitch: current.pre, end: current.loc)
    }

    var holdProgress: Double? {
        holdStart.map { min(Date().timeIntervalSince($0) / NoteCreationConstants.holdSeconds, 1) }
    }
}

/// A handle drag on an existing note: which pitches of segment `segment` move, by `offset`
/// semitones from `original`.
struct HandleEdit {
    enum Kind: String { case start, middle, end }
    var note: Int, segment: Int
    var kind: Kind
    var original: NoteTrajectory
    var press: CGPoint
    var offset = 0
}

extension AppState {
    /// Adds a note unless the same one is there, and saves.
    func addNote(_ n: NoteTrajectory) {
        guard !notes.contains(where: { $0.sameNote(as: n) }) else { return }
        notes.append(n)
        saveSession()
    }

    /// The note with `id` changed: segment `k`'s pitches moved by `offset` semitones from
    /// `original` (start: the first point's post-pitch, and on the note's first point its
    /// pre-pitch too; end: the next point's pre-pitch or the end pitch; middle: both).
    func applyHandleOffset(_ e: HandleEdit) {
        guard let i = notes.firstIndex(where: { $0.id == e.note }) else { return }
        var n = notes[i]
        n.points = e.original.points
        n.endPitch = e.original.endPitch
        let o = Float(e.offset), k = e.segment
        if e.kind != .end {
            n.points[k].post += o
            if k == 0 { n.points[0].pre += o }
        }
        if e.kind != .start {
            if k + 1 < n.points.count { n.points[k + 1].pre += o } else { n.endPitch += o }
        }
        if n != notes[i] { notes[i] = n }
    }
}

extension WaveformNSView {
    // MARK: Creating

    /// A press in a grid cell: the note's first segment, first point fixed.
    func startCreation(in cell: GridCell, at p: CGPoint) {
        guard let state else { return }
        state.clearNoteSelection()
        let pitch = Float(cell.note)
        let loc = state.beatGrid.loc(at: cell.startPos)
        creation = NoteCreation(current: NotePoint(pre: pitch, post: pitch, loc: loc), startPos: cell.startPos,
                                endPos: cell.endPos, endPitch: pitch, pointer: p)
        updateHold(at: p)
    }

    /// The pointer moved: the current segment follows a valid cell (at or after its start).
    func trackCreation(at p: CGPoint) {
        guard var c = creation else { return }
        c.pointer = p
        if !c.complete {
            if !underSpectrum(p), let cell = gridCell(at: p), cell.startPos >= c.startPos {
                c.valid = true
                c.endPos = cell.endPos
                let pitch = Float(cell.note)
                if !c.firstFixed { c.current.post = pitch }
                c.endPitch = pitch
            } else {
                c.valid = false
            }
        }
        creation = c
        updateHold(at: p)
    }

    /// Release (or Escape: `keepCurrent` false): adds the note (with the current segment if it is
    /// valid) unless it was added already.
    func finishCreation(keepCurrent: Bool) {
        guard let c = creation, let state else { creation = nil; return }
        creation = nil
        updateHoldTimer()
        guard !c.complete, let n = c.trajectory(state.beatGrid, withCurrent: keepCurrent && c.valid) else { return }
        state.addNote(n)
    }

    /// The note being created as drawn (with the current segment).
    func creationShape() -> NoteShape? {
        guard let state, let c = creation, !c.complete, let n = c.trajectory(state.beatGrid, withCurrent: true) else { return nil }
        return shape(of: n)
    }

    /// The drawn handle: the second point's (first point fixed) or the first point's; at the
    /// middle of an ellipse.
    func creationHandle() -> (centre: CGPoint, diameter: CGFloat)? {
        guard let c = creation, let sh = creationShape(), let sg = sh.segments.last else { return nil }
        let h = sg.handleCentres
        let centre = sg.isEllipse ? CGPoint(x: sg.ellipseBox.midX, y: sg.ellipseBox.midY) : c.firstFixed ? h[2] : h[0]
        return (centre, sg.width / 2)
    }

    /// Starts or stops the hold timer as the pointer enters or leaves the drawn handle.
    func updateHold(at p: CGPoint) {
        guard var c = creation else { return }
        let over = creationHandle().map { hypot($0.centre.x - p.x, $0.centre.y - p.y) <= $0.diameter / 2 + 1 } ?? false
        if !over {
            c.holdStart = nil
            c.armed = true
        } else if c.armed, c.holdStart == nil {
            c.holdStart = Date()
        }
        creation = c
        updateHoldTimer()
    }

    /// Runs the pie's redraw timer while the hold timer runs.
    func updateHoldTimer() {
        if creation?.holdStart != nil {
            guard holdTimer == nil else { return }
            let t = Timer(timeInterval: NoteCreationConstants.pieInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdTick() }
            }
            RunLoop.main.add(t, forMode: .common)
            holdTimer = t
        } else {
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }

    private func holdTick() {
        needsDisplay = true
        guard let progress = creation?.holdProgress, progress >= 1 else { return }
        holdElapsed()
    }

    /// The timer elapsed: on the second point's handle the current segment is finalised and the
    /// next one starts (first point not fixed), or, without a next grid cell, the note is added;
    /// on the first point's handle the first point gets fixed.
    func holdElapsed() {
        guard var c = creation, let state, let audio = state.audio else { return }
        c.holdStart = nil
        c.armed = false
        if c.firstFixed {
            let g = state.beatGrid
            let endTime = g.time(c.endPos, sampleRate: audio.sampleRate)
            if let next = gridCellSpan(beats: state.beats, barStarts: state.beatPositions.map(\.isBarStart),
                                       sampleRate: audio.sampleRate, gridDenominator: state.gridDenominator,
                                       time: endTime + 1e-6),
               next.startPos == c.endPos {
                c.finished.append(c.current)
                c.current = NotePoint(pre: c.endPitch, post: c.endPitch, loc: g.loc(at: c.endPos))
                c.startPos = c.endPos
                c.endPos = next.endPos
                c.firstFixed = false
                c.valid = false
            } else {
                if let n = c.trajectory(g, withCurrent: true) { state.addNote(n) }
                c.complete = true
            }
        } else {
            c.firstFixed = true
        }
        creation = c
        updateHold(at: c.pointer)
    }

    /// The hold timer's pie beside the pointer: a translucent accent sector growing clockwise from
    /// 12 o'clock, with a thin accent outline.
    func drawHoldPie() {
        guard let c = creation, let progress = c.holdProgress else { return }
        let r = pieRect(c)
        let centre = CGPoint(x: r.midX, y: r.midY), radius = r.width / 2
        let accent = NSColor.controlAccentColor
        let circle = NSBezierPath(ovalIn: r)
        NSColor.black.withAlphaComponent(0.35).setFill()
        circle.fill()
        if progress > 0 {
            // The view is flipped: 12 o'clock is −90°, and clockwise on screen is increasing angle.
            let pie = NSBezierPath()
            pie.move(to: centre)
            pie.appendArc(withCenter: centre, radius: radius, startAngle: -90, endAngle: -90 + 360 * progress, clockwise: false)
            pie.close()
            accent.withAlphaComponent(0.7).setFill()
            pie.fill()
        }
        circle.lineWidth = 1
        accent.setStroke()
        circle.stroke()
    }

    func pieRect(_ c: NoteCreation) -> NSRect {
        let d = NoteCreationConstants.pieDiameter, o = NoteCreationConstants.pieOffset
        return NSRect(x: c.pointer.x + o - d / 2, y: c.pointer.y + o - d / 2, width: d, height: d)
    }

    // MARK: Editing with the handles

    /// The handle under the point and its kind (by position; the only handle of a short segment
    /// is the middle one).
    func handleKind(at p: CGPoint) -> (note: NoteShape, segment: Int, kind: HandleEdit.Kind)? {
        guard let (sh, k) = hoveredSegment(at: p), let c = handle(at: p) else { return nil }
        let hs = sh.segments[k].visibleHandles
        let kind: HandleEdit.Kind = hs.count == 1 ? .middle : c == hs[0] ? .start : c == hs[2] ? .end : .middle
        return (sh, k, kind)
    }

    /// A press on a handle: selects only its segment and starts the drag.
    func startHandleEdit(at p: CGPoint) -> Bool {
        guard let state, let (sh, k, kind) = handleKind(at: p) else { return false }
        state.selectOnlySegment(SegmentRef(note: sh.note.id, segment: k))
        handleEdit = HandleEdit(note: sh.note.id, segment: k, kind: kind, original: sh.note, press: p)
        return true
    }

    /// Whole semitones from the press along the pitch axis, kept so the moved pitches stay in range.
    func trackHandleEdit(at p: CGPoint) {
        guard var e = handleEdit, let state else { return }
        var o = Int(((crossFromLow(p) - crossFromLow(e.press)) / CGFloat(SpectrogramConstants.pointsPerSemitone)).rounded())
        let n = e.original, k = e.segment
        var moved: [Float] = []
        if e.kind != .end { moved.append(n.points[k].post); if k == 0 { moved.append(n.points[0].pre) } }
        if e.kind != .start { moved.append(k + 1 < n.points.count ? n.points[k + 1].pre : n.endPitch) }
        let lo = Float(SpectrogramConstants.lowestNote), hi = Float(SpectrogramConstants.highestNote)
        if let mn = moved.min(), let mx = moved.max() {
            o = max(min(o, Int((hi - mx).rounded(.down))), Int((lo - mn).rounded(.up)))
        }
        guard o != e.offset else { return }
        e.offset = o
        handleEdit = e
        state.applyHandleOffset(e)
    }

    /// Release: saves if anything changed; Escape (`restore`): back to the pitches at the press.
    func finishHandleEdit(restore: Bool) {
        guard var e = handleEdit, let state else { return }
        handleEdit = nil
        if restore {
            e.offset = 0
            state.applyHandleOffset(e)
        } else if e.offset != 0 {
            state.saveSession()
        }
        needsDisplay = true
    }

    /// The segment whose handles are drawn: the edited one during a handle drag, none while
    /// creating, else the hovered one.
    func handleSegment() -> (note: NoteShape, segment: Int)? {
        if creation != nil { return nil }
        if let e = handleEdit {
            guard let n = state?.notes.first(where: { $0.id == e.note }), let sh = shape(of: n) else { return nil }
            return (sh, e.segment)
        }
        return hoverPoint.flatMap { hoveredSegment(at: $0) }
    }
}
