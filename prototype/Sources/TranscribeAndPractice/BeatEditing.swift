import AppKit

/// Placing, dragging and deleting beats; the time signature dialog; autosave (milestone 7).
extension AppState {
    /// System beep, counted for the state dump.
    func beep() {
        beepCount += 1
        NSSound.beep()
    }

    private var sampleRate: Double { audio?.sampleRate ?? 44100 }
    private var minDistanceSamples: Int { Int((BeatConstants.minBeatDistance * sampleRate).rounded(.up)) }

    /// B (`downbeat` false) / Shift+B: a beat at the pointer, or at the playhead while playing.
    func beatKey(downbeat: Bool) {
        guard let audio else { beep(); return }
        guard let t = isPlaying ? playhead : pointerTime else { beep(); return }
        let s = roundSample(t * audio.sampleRate)
        guard t >= 0, s >= 0, s < audio.frameCount else { beep(); return }
        if beats.contains(where: { abs($0.sample - s) < minDistanceSamples }) { beep(); return }
        var list = beats
        list.append(Beat(sample: s, timeSignature: nil, firstBeat: downbeat ? .placed : .no))
        list.sort { $0.sample < $1.sample }
        let first = list.first?.sample == s
        setBeats(recomputeBars(list), save: true)
        if first {
            if isPlaying { timeSignatureDialogPending = true } else { showTimeSignatureDialog() }
        }
    }

    /// Called when playback stops: the deferred dialog, if the first beat still has no signature.
    func playbackStopped() {
        guard timeSignatureDialogPending else { return }
        timeSignatureDialogPending = false
        if let first = beats.first, first.timeSignature == nil {
            showTimeSignatureDialog()
        }
    }

    private func showTimeSignatureDialog() {
        timeSignatureNumerator = "4"
        timeSignatureDenominator = 4
        timeSignatureDialogShown = true
    }

    /// The dialog's buttons: OK sets the first beat's signature, "Don't set" leaves it.
    func answerTimeSignatureDialog(ok: Bool) {
        timeSignatureDialogShown = false
        guard ok, audio != nil, let n = Int(timeSignatureNumerator), n >= 1, !beats.isEmpty else { return }
        var list = beats
        list[0].timeSignature = "\(n)/\(timeSignatureDenominator)"
        setBeats(recomputeBars(list), save: true)
    }

    var timeSignatureDialogValid: Bool { (Int(timeSignatureNumerator) ?? 0) >= 1 }

    // MARK: Strip editing

    /// Starts dragging the beat at `sample`; returns its index.
    func beginBeatDrag(sample: Int) -> Int? {
        guard audio != nil else { return nil }
        return beats.firstIndex { $0.sample == sample }
    }

    /// Moves the k-th beat towards time `t`, limited to 0.25 s from its neighbours,
    /// the visible range and the file; recomputes (saved on release, see `endBeatDrag`).
    func dragBeat(index k: Int, to t: Double) {
        guard let audio else { return }
        var list = beats
        guard list.indices.contains(k) else { return }
        let current = list[k].sample
        var lo = max(0, roundSample(max(viewStart, 0) * audio.sampleRate))
        var hi = min(audio.frameCount - 1, roundSample(viewEnd * audio.sampleRate))
        if k > 0 { lo = max(lo, list[k - 1].sample + minDistanceSamples) }
        if k + 1 < list.count { hi = min(hi, list[k + 1].sample - minDistanceSamples) }
        if lo > hi { lo = min(lo, current); hi = max(hi, current); if lo > hi { return } }
        let s = min(max(roundSample(t * audio.sampleRate), lo), hi)
        guard s != current else { return }
        list[k].sample = s
        setBeats(recomputeBars(list), save: false)
    }

    func endBeatDrag() { saveBeats() }

    /// Backspace over a beat mark: deletes the beat (its signature moves to the next beat unless
    /// that has one).
    func deleteHoveredBeat() {
        guard audio != nil, let s = hoveredBeatSample else { return }
        var list = beats
        guard let k = list.firstIndex(where: { $0.sample == s }) else { return }
        let ts = list[k].timeSignature
        list.remove(at: k)
        if let ts, k < list.count, list[k].timeSignature == nil { list[k].timeSignature = ts }
        hoveredBeatSample = nil
        setBeats(recomputeBars(list), save: true)
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
