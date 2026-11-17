import AppKit
import QuartzCore

/// Calls `tick` at the display refresh rate while playing (and while follow is easing).
@MainActor
final class Ticker: NSObject {
    private var link: CADisplayLink?
    private let tick: (Double) -> Bool
    private var last: CFTimeInterval = 0

    /// `tick(dt)` returns false to stop the ticker.
    init(tick: @escaping (Double) -> Bool) {
        self.tick = tick
        super.init()
        guard let screen = NSScreen.main else { return }
        link = screen.displayLink(target: self, selector: #selector(fire(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func fire(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last == 0 ? link.duration : now - last
        last = now
        if !tick(dt) { invalidate() }
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }
}

extension AppState {
    /// Playback follows the selection at least this long when following the playhead.
    static let followMinLength = 5.0
    /// Easing time constant of follow, in seconds.
    static let followTimeConstant = 0.5

    var selectionFrames: (lo: Int, hi: Int)? {
        guard let s = selection, let audio else { return nil }
        return (Int((s.lowerBound * audio.sampleRate).rounded()), Int((s.upperBound * audio.sampleRate).rounded()))
    }

    /// Selection start, or where the user last clicked to clear the selection.
    var rewindPoint: Double { selection?.lowerBound ?? clearPoint }

    // MARK: Actions

    func playOrStop() {
        if isPlaying { stopPlayback() } else { startPlayback(at: playhead) }
    }

    func rewindAndPlay() {
        startPlayback(at: rewindPoint)
    }

    func playAgain() {
        startPlayback(at: lastStart)
    }

    func startPlayback(at time: Double) {
        guard let audio else { return }
        let t = min(max(time, 0), audio.duration)
        player.ensureRunning()
        player.core.start(at: Int((t * audio.sampleRate).rounded()), selection: selectionFrames, loop: loopEnabled)
        playhead = t
        lastStart = t
        setPlaying(true)
        if ticker == nil {
            ticker = Ticker { [weak self] dt in self?.tick(dt) ?? false }
        }
    }

    /// Stops; the playhead stays at the audible position.
    func stopPlayback() {
        guard isPlaying, let audio else { return }
        let frame = player.core.stop()
        playhead = Double(frame) / audio.sampleRate
        setPlaying(false)
    }

    /// A click without a drag: clears the selection, stops, sets the playhead and rewind point.
    func clickedToClear(at time: Double) {
        stopPlayback()
        let t = min(max(time, 0), duration)
        selection = nil
        playhead = t
        clearPoint = t
    }

    /// Escape: clears the selection, stops, playhead to the former selection start.
    func clearSelectionWithKey() {
        guard let s = selection else { return }
        stopPlayback()
        selection = nil
        playhead = s.lowerBound
        clearPoint = s.lowerBound
    }

    /// A new selection drag has started: stops playback.
    func newSelectionStarted() { stopPlayback() }

    /// After a new selection drag: the playhead is at the selection start.
    func newSelectionChanged() {
        if let s = selection { playhead = s.lowerBound }
    }

    /// A manual view change (scroll, pinch, pan, scrollbar, zoom buttons) turns follow off
    /// during playback.
    func manualViewChange() {
        if isPlaying && followPlayhead { followPlayhead = false }
    }

    // MARK: Display tick

    /// Updates the playhead from the audio side, handles the end of playback, eases the view
    /// when following. Returns false when nothing is left to do.
    private func tick(_ dt: Double) -> Bool {
        guard let audio else { ticker = nil; return false }
        if isPlaying {
            if let rewind = player.core.takeEnded() {
                setPlaying(false)
                playhead = Double(rewind) / audio.sampleRate
            } else {
                playhead = Double(player.core.withLock { player.core.playheadFrame }) / audio.sampleRate
            }
        }
        if isPlaying && followPlayhead { follow(dt) }
        if !isPlaying {
            ticker?.invalidate()
            ticker = nil
            return false
        }
        return true
    }

    /// Eases the view toward the playhead in the center and at least 5 s long.
    private func follow(_ dt: Double) {
        let a = 1 - exp(-max(dt, 0) / Self.followTimeConstant)
        let (lo, hi) = viewLimits
        let targetLength = max(viewLength, min(Self.followMinLength, hi - lo))
        let length = viewLength + (targetLength - viewLength) * a
        // Ease the playhead's offset from the center (no lag behind the moving playhead).
        let center = (viewStart + viewEnd) / 2
        let offset = (playhead - center) * (1 - a)
        let newCenter = playhead - offset
        setView(start: newCenter - length / 2, end: newCenter + length / 2)
    }
}
