import AppKit

// Milestone 15: creating notes by dragging and editing pitches with the handles. See the spec,
// "Creating notes by dragging" and "Editing pitches with the handles".

/// The note being created by a drag: from `start` (at `startPos`) to `endPos`.
struct NoteCreation {
    var start: GridLoc
    var startPos: Rational, endPos: Rational
    var startPitch: Float, endPitch: Float
    /// The pointer was over a valid cell at the last update (a release adds the note).
    var valid = true

    func note(_ g: BeatGrid) -> Note {
        Note(start: start, startPitch: startPitch, end: g.loc(at: endPos), endPitch: endPitch)
    }
}

/// A handle drag on an existing note: which pitches move, by `offset` semitones from `original`.
struct HandleEdit {
    enum Kind: String { case start, middle, end }
    var note: Int
    var kind: Kind
    var original: Note
    var press: CGPoint
    var offset = 0
}

extension AppState {
    /// The note with `e.note` changed: its pitches moved by `e.offset` semitones from the
    /// original (start handle: the start pitch; end handle: the end pitch; middle: both).
    func applyHandleOffset(_ e: HandleEdit) {
        guard let i = notes.firstIndex(where: { $0.id == e.note }) else { return }
        var n = notes[i]
        let o = Float(e.offset)
        n.startPitch = e.original.startPitch + (e.kind == .end ? 0 : o)
        n.endPitch = e.original.endPitch + (e.kind == .start ? 0 : o)
        if n != notes[i] { notes[i] = n }
    }
}

extension WaveformNSView {
    // MARK: Creating

    /// A press in a grid cell: a one-cell note at the cell's note.
    func startCreation(in cell: GridCell) {
        guard let state else { return }
        state.clearNoteSelection()
        let pitch = Float(cell.note)
        creation = NoteCreation(start: state.beatGrid.loc(at: cell.startPos), startPos: cell.startPos, endPos: cell.endPos,
                                startPitch: pitch, endPitch: pitch)
    }

    /// The pointer moved: the note ends at a valid cell's end (at or after its start), at the
    /// pointer's note; elsewhere it stays and is marked invalid.
    func trackCreation(at p: CGPoint) {
        guard var c = creation else { return }
        if !underSpectrum(p), let cell = gridCell(at: p), cell.startPos >= c.startPos {
            c.valid = true
            c.endPos = cell.endPos
            c.endPitch = Float(cell.note)
        } else {
            c.valid = false
        }
        creation = c
    }

    /// Release (`add`) or Escape: adds the note if it is valid.
    func finishCreation(add: Bool) {
        guard let c = creation, let state else { creation = nil; return }
        creation = nil
        if add, c.valid { state.addNote(c.note(state.beatGrid)) }
    }

    /// The note being created as drawn.
    func creationShape() -> NoteShape? {
        guard let state, let c = creation else { return nil }
        return shape(of: c.note(state.beatGrid))
    }

    /// The end handle of the note being created (at the middle of an ellipse).
    func creationHandle() -> (centre: CGPoint, diameter: CGFloat)? {
        guard let sh = creationShape() else { return nil }
        return (sh.isEllipse ? CGPoint(x: sh.ellipseBox.midX, y: sh.ellipseBox.midY) : sh.handleCentres[2], sh.width / 2)
    }

    // MARK: Editing with the handles

    /// The handle under the point and its kind (the only handle of a short note is the middle one).
    func handleKind(at p: CGPoint) -> (note: NoteShape, kind: HandleEdit.Kind)? {
        guard let sh = hoveredNote(at: p), let c = handle(at: p) else { return nil }
        let hs = sh.visibleHandles
        return (sh, hs.count == 1 ? .middle : c == hs[0] ? .start : c == hs[2] ? .end : .middle)
    }

    /// A press on a handle: selects only its note and starts the drag.
    func startHandleEdit(at p: CGPoint) -> Bool {
        guard let state, let (sh, kind) = handleKind(at: p) else { return false }
        state.selectOnlyNote(id: sh.note.id)
        handleEdit = HandleEdit(note: sh.note.id, kind: kind, original: sh.note, press: p)
        return true
    }

    /// Whole semitones from the press along the pitch axis, kept so the moved pitches stay in range.
    func trackHandleEdit(at p: CGPoint) {
        guard var e = handleEdit, let state else { return }
        var o = Int(((crossFromLow(p) - crossFromLow(e.press)) / CGFloat(SpectrogramConstants.pointsPerSemitone)).rounded())
        let n = e.original
        let moved = (e.kind == .end ? [] : [n.startPitch]) + (e.kind == .start ? [] : [n.endPitch])
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

    /// The note whose handles are drawn: the edited one during a handle drag, none while
    /// creating, else the hovered one.
    func handleNote() -> NoteShape? {
        if creation != nil { return nil }
        if let e = handleEdit {
            return state?.notes.first(where: { $0.id == e.note }).flatMap { shape(of: $0) }
        }
        return hoverPoint.flatMap { hoveredNote(at: $0) }
    }
}
