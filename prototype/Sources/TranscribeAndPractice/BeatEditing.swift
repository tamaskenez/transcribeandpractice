import AppKit

/// Placing, dragging and deleting beats; the time signature dialog; autosave (milestone 7).
extension AppState {
    /// System beep, counted for the state dump.
    func beep() {
        beepCount += 1
        NSSound.beep()
    }

    private var sampleRate: Double { audio?.sampleRate ?? 44100 }
    private var minDistanceSamples: Int { Int((BeatConstants.minPlacedDistance * sampleRate).rounded(.up)) }

    /// B (`downbeat` false) / Shift+B: a placed beat at the pointer, or at the playhead while playing.
    func beatKey(downbeat: Bool) {
        guard let audio else { beep(); return }
        guard let t = isPlaying ? playhead : pointerTime else { beep(); return }
        let s = roundSample(t * audio.sampleRate)
        guard t >= 0, s >= 0, s < audio.frameCount else { beep(); return }
        if beats.contains(where: { $0.source == .placed && abs($0.sample - s) < minDistanceSamples }) { beep(); return }
        var list = beats.filter { $0.sample != s }
        list.append(Beat(sample: s, source: .placed, timeSignature: nil, firstBeat: downbeat ? .placed : .no))
        list.sort { $0.sample < $1.sample }
        let first = list.first { $0.source == .placed }?.sample == s
        setBeats(recomputeBeats(list, sampleRate: audio.sampleRate, frameCount: audio.frameCount), save: true)
        if first {
            if isPlaying { timeSignatureDialogPending = true } else { showTimeSignatureDialog() }
        }
    }

    /// Called when playback stops: the deferred dialog, if the first beat still has no signature.
    func playbackStopped() {
        guard timeSignatureDialogPending else { return }
        timeSignatureDialogPending = false
        if let first = beats.first(where: { $0.source == .placed }), first.timeSignature == nil {
            showTimeSignatureDialog()
        }
    }

    private func showTimeSignatureDialog() {
        timeSignatureNumerator = "4"
        timeSignatureDenominator = 4
        timeSignatureDialogShown = true
    }

    /// The dialog's buttons: OK sets the first placed beat's signature, "Don't set" leaves it.
    func answerTimeSignatureDialog(ok: Bool) {
        timeSignatureDialogShown = false
        guard ok, let audio, let n = Int(timeSignatureNumerator), n >= 1,
              let i = beats.firstIndex(where: { $0.source == .placed }) else { return }
        var list = beats
        list[i].timeSignature = "\(n)/\(timeSignatureDenominator)"
        setBeats(recomputeBeats(list, sampleRate: audio.sampleRate, frameCount: audio.frameCount), save: true)
    }

    var timeSignatureDialogValid: Bool { (Int(timeSignatureNumerator) ?? 0) >= 1 }

    // MARK: Strip editing

    /// Starts dragging the beat at `sample`: a computed beat becomes placed. Returns its index
    /// among the placed beats.
    func beginBeatDrag(sample: Int) -> Int? {
        guard let audio, let i = beats.firstIndex(where: { $0.sample == sample }) else { return nil }
        var list = beats
        if list[i].source == .computed {
            list[i].source = .placed
            setBeats(recomputeBeats(list, sampleRate: audio.sampleRate, frameCount: audio.frameCount), save: false)
        }
        return beats.filter { $0.source == .placed }.firstIndex { $0.sample == sample }
    }

    /// Moves the k-th placed beat towards time `t`, limited to 0.25 s from its placed neighbours,
    /// the visible range and the file; recomputes (saved on release, see `endBeatDrag`).
    func dragBeat(placedIndex k: Int, to t: Double) {
        guard let audio else { return }
        var placed = beats.filter { $0.source == .placed }
        guard placed.indices.contains(k) else { return }
        let current = placed[k].sample
        var lo = max(0, roundSample(max(viewStart, 0) * audio.sampleRate))
        var hi = min(audio.frameCount - 1, roundSample(viewEnd * audio.sampleRate))
        if k > 0 { lo = max(lo, placed[k - 1].sample + minDistanceSamples) }
        if k + 1 < placed.count { hi = min(hi, placed[k + 1].sample - minDistanceSamples) }
        if lo > hi { lo = min(lo, current); hi = max(hi, current); if lo > hi { return } }
        let s = min(max(roundSample(t * audio.sampleRate), lo), hi)
        guard s != current else { return }
        placed[k].sample = s
        setBeats(recomputeBeats(placed, sampleRate: audio.sampleRate, frameCount: audio.frameCount), save: false)
    }

    func endBeatDrag() { saveBeats() }

    /// Backspace over a beat mark: deletes a placed beat (its signature moves to the next placed
    /// beat unless that has one); a computed beat beeps.
    func deleteHoveredBeat() {
        guard let audio, let s = hoveredBeatSample, let beat = beats.first(where: { $0.sample == s }) else { return }
        guard beat.source == .placed else { beep(); return }
        var placed = beats.filter { $0.source == .placed }
        guard let k = placed.firstIndex(where: { $0.sample == s }) else { return }
        let ts = placed[k].timeSignature
        placed.remove(at: k)
        if let ts, k < placed.count, placed[k].timeSignature == nil { placed[k].timeSignature = ts }
        hoveredBeatSample = nil
        setBeats(recomputeBeats(placed, sampleRate: audio.sampleRate, frameCount: audio.frameCount), save: true)
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
