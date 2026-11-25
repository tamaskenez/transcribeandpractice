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

    /// Each note: a raised 2-point frame inside its area, lit from the top left: the outer ring
    /// is white on the top and left edges and black on the bottom and right; the inner ring the
    /// other way round.
    func drawNotes() {
        let white = NSBezierPath(), black = NSBezierPath()
        for (_, r) in noteRects() {
            // Ring `i` (0 outer, 1 inner): top-left in `tl`, bottom-right in `br`.
            for i in 0..<2 {
                let q = r.insetBy(dx: CGFloat(i), dy: CGFloat(i))
                guard q.width >= 2, q.height >= 2 else { break }
                let (tl, br) = i == 0 ? (white, black) : (black, white)
                // The view is flipped: minY is the top.
                tl.appendRect(NSRect(x: q.minX, y: q.minY, width: q.width - 1, height: 1)) // top
                tl.appendRect(NSRect(x: q.minX, y: q.minY, width: 1, height: q.height - 1)) // left
                br.appendRect(NSRect(x: q.minX, y: q.maxY - 1, width: q.width, height: 1)) // bottom
                br.appendRect(NSRect(x: q.maxX - 1, y: q.minY, width: 1, height: q.height)) // right
            }
        }
        NSColor.white.setFill(); white.fill()
        NSColor.black.setFill(); black.fill()
    }
}
