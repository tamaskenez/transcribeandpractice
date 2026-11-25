import AppKit

/// The beat dialogs opened from the beat context menu.
enum BeatDialog: Equatable {
    /// Time signature of the beat with this id.
    case timeSignature(id: Int)
    case subdivide
}

/// Placing, selecting, moving and deleting beats; the beat context menu's actions; autosave.
extension AppState {
    /// System beep, counted for the state dump.
    func beep() {
        beepCount += 1
        NSSound.beep()
    }

    private var sampleRate: Double { audio?.sampleRate ?? 44100 }
    private var minDistanceSamples: Int { Int((BeatConstants.minBeatDistance * sampleRate).rounded(.up)) }

    /// B (`downbeat` false) / Shift+B: a beat at the pointer, or at the playhead while playing
    /// (Shift: a forced bar start).
    func beatKey(downbeat: Bool) {
        guard let audio else { beep(); return }
        guard let t = isPlaying ? playhead : pointerTime else { beep(); return }
        let s = roundSample(t * audio.sampleRate)
        guard t >= 0, s >= 0, s < audio.frameCount else { beep(); return }
        if beats.contains(where: { abs($0.sample - s) < minDistanceSamples }) { beep(); return }
        var list = beats
        list.append(Beat(sample: s, bar: downbeat ? .start : .auto))
        list.sort { $0.sample < $1.sample }
        setBeats(list, save: true)
    }

    // MARK: Selection

    /// Plain click on a beat: only that beat is selected.
    func selectOnlyBeat(id: Int) {
        selectedBeats = [id]
        beatAnchor = id
    }

    /// Command+click: toggles the beat; a newly selected beat becomes the anchor.
    func toggleBeat(id: Int) {
        if selectedBeats.remove(id) == nil {
            selectedBeats.insert(id)
            beatAnchor = id
        }
    }

    /// Shift+click: adds the beats from the anchor to this one (only this one without an anchor).
    func selectBeatRange(to id: Int) {
        guard let a = beatAnchor, let i = beats.firstIndex(where: { $0.id == a }),
              let j = beats.firstIndex(where: { $0.id == id }) else { selectOnlyBeat(id: id); return }
        for k in min(i, j)...max(i, j) { selectedBeats.insert(beats[k].id) }
    }

    func clearBeatSelection() {
        selectedBeats = []
        beatAnchor = nil
    }

    /// Indices of the selected beats, ascending.
    var selectedBeatIndices: [Int] { beats.indices.filter { selectedBeats.contains(beats[$0].id) } }

    // MARK: Moving

    /// Moves the beats in `original` (id → sample at the press) together by `dt` seconds, limited
    /// so that none comes closer than the minimum distance to an unmoved neighbour (the order never
    /// changes) or leaves the file. Saved on release (`endBeatMove`).
    func moveBeats(original: [Int: Int], by dt: Double) {
        guard let audio, !original.isEmpty else { return }
        var lo = Int.min / 2, hi = Int.max / 2
        for (k, b) in beats.enumerated() {
            guard let s0 = original[b.id] else { continue }
            lo = max(lo, -s0)
            hi = min(hi, audio.frameCount - 1 - s0)
            if k > 0, original[beats[k - 1].id] == nil { lo = max(lo, beats[k - 1].sample + minDistanceSamples - s0) }
            if k + 1 < beats.count, original[beats[k + 1].id] == nil {
                hi = min(hi, beats[k + 1].sample - minDistanceSamples - s0)
            }
        }
        if lo > hi { lo = min(lo, 0); hi = max(hi, 0); if lo > hi { return } }
        let d = min(max(Int((dt * audio.sampleRate).rounded()), lo), hi)
        var list = beats
        for k in list.indices { if let s0 = original[list[k].id] { list[k].sample = s0 + d } }
        guard list != beats else { return }
        setBeats(list, save: false)
    }

    func endBeatMove() { saveBeats() }

    // MARK: Context menu actions

    /// Deletes the selected beats (Backspace: the selection, else the beat under the pointer).
    func deleteSelectedBeats() {
        guard !selectedBeats.isEmpty else { return }
        let gone = selectedBeats
        clearBeatSelection()
        hoveredBeatSample = nil
        setBeats(beats.filter { !gone.contains($0.id) }, save: true)
    }

    func deleteHoveredBeat() {
        if !selectedBeats.isEmpty { deleteSelectedBeats(); return }
        guard let s = hoveredBeatSample else { return }
        hoveredBeatSample = nil
        setBeats(beats.filter { $0.sample != s }, save: true)
    }

    /// "Beat within bar" of a single beat.
    func setBar(_ bar: Beat.Bar, id: Int) {
        guard let i = beats.firstIndex(where: { $0.id == id }), beats[i].bar != bar else { return }
        var list = beats
        list[i].bar = bar
        setBeats(list, save: true)
    }

    /// The beat's position in its bar if it counted automatically (for "Auto (2nd)").
    func autoBeatInBar(id: Int) -> Int? {
        guard let i = beats.firstIndex(where: { $0.id == id }) else { return nil }
        var list = beats
        list[i].bar = .auto
        return barLayout(list)[i].beatInBar
    }

    /// The signature in effect at the beat if it set none.
    private func inheritedSignature(at i: Int) -> TimeSignature {
        var list = beats
        list[i].timeSignature = nil
        return barLayout(list)[i].signature
    }

    /// "Time signature...": prefilled with the beat's own signature ("change") or the inherited one ("continue").
    func openTimeSignatureDialog(id: Int) {
        guard let i = beats.firstIndex(where: { $0.id == id }) else { return }
        tsInherited = inheritedSignature(at: i)
        let own = TimeSignature(beats[i].timeSignature)
        let shown = own ?? tsInherited
        tsFilling = true
        tsNumerator = String(shown.num)
        tsDenominator = shown.den
        tsChange = own != nil
        tsFilling = false
        beatDialog = .timeSignature(id: id)
    }

    /// A numerator or denominator different from the inherited signature selects "change".
    func tsFieldsChanged() {
        if !tsFilling, !tsChange, Int(tsNumerator) != tsInherited.num || tsDenominator != tsInherited.den { tsChange = true }
    }

    var tsDialogValid: Bool { !tsChange || (Int(tsNumerator) ?? 0) >= 1 }

    /// OK: "change" sets the signature on the beat (a forced bar start), "continue" removes it.
    func answerTimeSignatureDialog(ok: Bool) {
        defer { beatDialog = nil }
        guard ok, tsDialogValid, case let .timeSignature(id) = beatDialog,
              let i = beats.firstIndex(where: { $0.id == id }) else { return }
        var list = beats
        list[i].timeSignature = tsChange ? "\(Int(tsNumerator)!)/\(tsDenominator)" : nil
        guard list != beats else { return }
        setBeats(list, save: true)
    }

    /// Pairs of neighbouring beats that are both selected (the gaps Subdivide splits).
    private var selectedGaps: [(Int, Int)] {
        let sel = selectedBeatIndices
        return zip(sel, sel.dropFirst()).filter { $1 == $0 + 1 }
    }

    var canSubdivide: Bool { !selectedGaps.isEmpty }

    /// The largest n keeping the new beats the minimum distance apart.
    var maxSubdivision: Int {
        selectedGaps.map { (beats[$0.1].sample - beats[$0.0].sample) / max(minDistanceSamples, 1) }.min() ?? 0
    }

    var subdivideValue: Int? {
        guard let n = Int(subdivideText), n >= 2, n <= maxSubdivision else { return nil }
        return n
    }

    func openSubdivideDialog() {
        guard canSubdivide else { beep(); return }
        subdivideText = "2"
        beatDialog = .subdivide
    }

    /// Subdivide: each gap between two neighbouring selected beats becomes n equal gaps (new beats
    /// count automatically and are not selected).
    func answerSubdivideDialog(ok: Bool) {
        defer { beatDialog = nil }
        guard ok, let n = subdivideValue else { return }
        var list = beats
        for (a, b) in selectedGaps {
            let s0 = Double(beats[a].sample), s1 = Double(beats[b].sample)
            for j in 1..<n { list.append(Beat(sample: roundSample(s0 + Double(j) * (s1 - s0) / Double(n)))) }
        }
        list.sort { $0.sample < $1.sample }
        setBeats(list, save: true)
    }

    /// Bars whose start and the next bar start are both selected: (start index, next start index).
    private var equalizableBars: [(Int, Int)] {
        let starts = beats.indices.filter { beatPositions[$0].isBarStart }
        return zip(starts, starts.dropFirst()).filter {
            selectedBeats.contains(beats[$0.0].id) && selectedBeats.contains(beats[$0.1].id)
        }
    }

    var canEqualize: Bool { equalizableBars.contains { $0.1 > $0.0 + 1 } }

    /// "Equalize beats within bars": in each such bar the beats between the two bar starts are
    /// spaced equally.
    func equalizeBeatsWithinBars() {
        var list = beats
        for (a, b) in equalizableBars {
            let s0 = Double(beats[a].sample), s1 = Double(beats[b].sample)
            for k in (a + 1)..<b { list[k].sample = roundSample(s0 + Double(k - a) * (s1 - s0) / Double(b - a)) }
        }
        guard list != beats else { return }
        setBeats(list, save: true)
    }

    // MARK: Saving

    func saveBeats() {
        guard let audio else { return }
        let url = BeatFile.sidecarURL(for: audio.url)
        do {
            try BeatFile.encode(beats).write(to: url, options: .atomic)
        } catch {
            errorTitle = "Could not save beats"
            errorMessage = "“\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }
}
