import AppKit
import Observation
import UniformTypeIdentifiers

let appName = "Transcribe and Practice"

/// Direction of the time axis in the navigator and main panes.
enum TimeOrientation: String, CaseIterable {
    case horizontal // time runs to the right
    case vertical   // time runs downwards
}

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    private(set) var audio: LoadedAudio?
    /// Text of the error alert; non-nil while the alert is shown.
    var errorMessage: String?
    var errorTitle = "Could not open file"

    /// Beats of the loaded file, sorted by sample (from the sidecar file, see Beats.swift).
    private(set) var beats: [Beat] = []
    func setBeats(_ list: [Beat], save: Bool) {
        beats = list
        if save { saveBeats() }
    }
    /// Beeps so far (for the state dump).
    var beepCount = 0
    /// Time signature dialog (see BeatEditing.swift).
    var timeSignatureDialogShown = false
    var timeSignatureDialogPending = false
    /// The numerator field: digits only.
    var timeSignatureNumerator = "4" {
        didSet {
            let digits = timeSignatureNumerator.filter { $0.isASCII && $0.isNumber }
            if digits != timeSignatureNumerator { timeSignatureNumerator = digits }
        }
    }
    var timeSignatureDenominator = 4
    /// The beat mark under the pointer in the strip (stopped, beats mode), by sample.
    var hoveredBeatSample: Int?
    /// Stored "Show Beats" choice (remembered); the strip shows beats only if there are any.
    var showBeats: Bool {
        didSet { UserDefaults.standard.set(showBeats, forKey: Self.showBeatsKey) }
    }
    var beatsAvailable: Bool { !beats.isEmpty }
    /// Number of downbeats (bars) in the file.
    var barCount: Int { beats.count { $0.isDownbeat } }
    var stripShowsBeats: Bool { showBeats && beatsAvailable }
    private static let showBeatsKey = "showBeats"

    /// Time under the mouse pointer while it is over a waveform pane or the strip (nil otherwise),
    /// as the pane's name and the fraction along its time axis, so that it follows view changes.
    var pointer: (pane: String, fraction: Double)?
    var pointerTime: Double? { pointer.map { viewStart + $0.fraction * viewLength } }

    var orientation: TimeOrientation {
        didSet { UserDefaults.standard.set(orientation.rawValue, forKey: Self.orientationKey) }
    }
    /// Navigator share of the middle section (0...1).
    var navigatorFraction: CGFloat = 0.2
    /// Pane frames in window content coordinates (top-left origin), for the state dump.
    var paneFrames: [String: CGRect] = [:]

    /// Visible time range (seconds) shared by the navigator and the main pane.
    private(set) var viewStart: Double = 0
    private(set) var viewEnd: Double = 0
    /// Selected time range (seconds), start <= end.
    var selection: ClosedRange<Double>? {
        didSet { player.core.setSelection(selectionFrames) }
    }

    // Playback (see Playback.swift).
    let player = Player()
    /// Playhead (seconds), updated from the audio callbacks while playing.
    var playhead: Double = 0
    private(set) var isPlaying = false
    /// Where the user last clicked to clear the selection / set the playhead.
    var clearPoint: Double = 0
    /// Where the most recent playback started.
    var lastStart: Double = 0
    var loopEnabled: Bool {
        didSet {
            UserDefaults.standard.set(loopEnabled, forKey: Self.loopKey)
            player.core.setLoop(loopEnabled)
        }
    }
    var followPlayhead: Bool {
        didSet {
            UserDefaults.standard.set(followPlayhead, forKey: Self.followKey)
            followEngaged = false
            followLastPlayhead = nil
        }
    }
    /// Follow has started moving the view during this playback (see `follow`).
    var followEngaged = false
    /// Playhead at the previous follow step (the view moves along with it).
    var followLastPlayhead: Double?
    var ticker: Ticker?
    private static let loopKey = "loopEnabled"
    /// Follow's own unrounded view (the view itself pans by whole pixels).
    var followExact: (start: Double, end: Double)?
    private static let followKey = "followPlayhead"

    func setPlaying(_ on: Bool) {
        let was = isPlaying
        isPlaying = on
        if was && !on { playbackStopped() }
    }

    /// Shortest visible range (maximum zoom), in seconds.
    static let minViewLength = 0.1
    /// The visible range may extend this far before the start and after the end of the file.
    static let viewMargin = minViewLength / 2

    private static let orientationKey = "timeOrientation"

    // Spectrogram (milestone 8; see Spectrogram.swift).
    var mainMode: MainPaneMode {
        didSet { UserDefaults.standard.set(mainMode.rawValue, forKey: Self.mainModeKey) }
    }
    /// Window length slider value (ms), 10…500.
    var windowLengthMs: Double {
        didSet {
            let v = min(max(windowLengthMs, Self.minWindowMs), Self.maxWindowMs)
            if v != windowLengthMs { windowLengthMs = v; return }
            UserDefaults.standard.set(windowLengthMs, forKey: Self.windowKey)
        }
    }
    /// The background computation is working.
    var spectrogramBusy = false
    /// Bumped when computed columns arrive (redraws the main pane).
    var spectrogramVersion = 0
    /// Frequency view: semitones above A0 − ½ at the pane's low edge; nil = centred on C4.
    var freqLow: Double?
    /// Main pane size along / across the time axis (points).
    var mainAxisLength: CGFloat = 0
    var mainCrossLength: CGFloat = 0
    /// Fraction of a pixel left over from the previous scroll pan.
    var panRemainder = 0.0
    /// The last scroll event's deltas and whether they were precise (for the state dump).
    var lastScrollDelta: [Double] = []
    /// Increments on every file open (identifies the audio for the spectrogram cache).
    var loadID = 0
    @ObservationIgnored let spectrogram = SpectrogramEngine()
    @ObservationIgnored let spectrum = SpectrumEngine()
    static let minWindowMs = 10.0, maxWindowMs = 500.0
    private static let mainModeKey = "mainPaneMode", windowKey = "spectrogramWindowMs"

    init() {
        orientation = UserDefaults.standard.string(forKey: Self.orientationKey)
            .flatMap(TimeOrientation.init(rawValue:)) ?? .horizontal
        loopEnabled = UserDefaults.standard.bool(forKey: Self.loopKey)
        followPlayhead = UserDefaults.standard.bool(forKey: Self.followKey)
        showBeats = UserDefaults.standard.object(forKey: Self.showBeatsKey) as? Bool ?? true
        mainMode = UserDefaults.standard.string(forKey: Self.mainModeKey).flatMap(MainPaneMode.init(rawValue:)) ?? .waveform
        windowLengthMs = min(max(UserDefaults.standard.object(forKey: Self.windowKey) as? Double ?? 50, Self.minWindowMs), Self.maxWindowMs)
        player.core.setLoop(loopEnabled)
    }

    var windowTitle: String { audio?.fileName ?? appName }

    /// One-line summary in the transport pane.
    var transportSummary: String? {
        guard let audio else { return nil }
        let rows = Dictionary(infoRows(for: audio).map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        return ["File", "Duration", "Sample rate", "Channels"].compactMap { rows[$0] }.joined(separator: "  ·  ")
    }

    var duration: Double { audio?.duration ?? 0 }
    var viewLength: Double { viewEnd - viewStart }
    /// Limits of the visible range: the file plus a margin at both ends.
    var viewLimits: (lower: Double, upper: Double) { (-Self.viewMargin, duration + Self.viewMargin) }
    var isFullView: Bool { viewStart <= viewLimits.lower && viewEnd >= viewLimits.upper }
    var canZoomOutFull: Bool { audio != nil && (!isFullView || amplitudeZoomDB > 0) }

    /// Amplitude zoom of both waveform panes, in dB (0 = full scale fills the pane).
    private(set) var amplitudeZoomDB: Double = 0
    static let maxAmplitudeZoomDB = 60.0
    /// Multiplier applied to sample values when drawing.
    var amplitudeGain: Double { pow(10, amplitudeZoomDB / 20) }

    /// Sets the amplitude zoom, limited to 0…60 dB.
    func setAmplitudeZoom(dB: Double) {
        guard dB.isFinite else { return }
        amplitudeZoomDB = min(max(dB, 0), Self.maxAmplitudeZoomDB)
    }

    /// Multiplies the amplitude gain by `factor` (> 1 zooms in).
    func zoomAmplitude(by factor: Double) {
        guard factor > 0 else { return }
        setAmplitudeZoom(dB: amplitudeZoomDB + 20 * log10(factor))
    }

    /// Moves the selection by `seconds`, keeping its length; it stays within the file.
    func moveSelection(from original: ClosedRange<Double>, by seconds: Double) {
        let length = original.upperBound - original.lowerBound
        let start = min(max(original.lowerBound + seconds, 0), duration - length)
        selection = start...(start + length)
    }
    var canZoomToSelection: Bool { audio != nil && selection != nil }

    /// Sets the visible range, applying the limits: length at least minViewLength and at most
    /// the limits' span, keeping the requested center; then shifted inside the limits.
    /// Continuous (not a pan): drops the pan remainder.
    func setView(start: Double, end: Double) {
        panRemainder = 0
        applyView(start: start, end: end)
    }

    private func applyView(start: Double, end: Double) {
        let (lo, hi) = viewLimits
        guard duration > 0, start.isFinite, end.isFinite else { viewStart = 0; viewEnd = duration; return }
        var a = min(start, end), b = max(start, end)
        let length = min(max(b - a, Self.minViewLength), hi - lo)
        if length != b - a {
            let center = (a + b) / 2
            a = center - length / 2
            b = a + length
        }
        if a < lo { a = lo; b = lo + length }
        if b > hi { b = hi; a = hi - length }
        viewStart = max(a, lo)
        viewEnd = min(b, hi)
    }

    /// Zooms by `factor` (> 1 zooms in) keeping `anchor` (seconds) at the same place on screen.
    func zoom(by factor: Double, anchor: Double) {
        guard factor > 0, viewLength > 0 else { return }
        let (lo, hi) = viewLimits
        let length = min(max(viewLength / factor, Self.minViewLength), hi - lo)
        let frac = (anchor - viewStart) / viewLength
        let start = anchor - frac * length
        setView(start: start, end: start + length)
    }

    /// Pixels (points) along the time axis of the panes.
    var timePixels: Int { Int(Double(mainAxisLength).rounded()) }
    /// Seconds per pixel; nil before the main pane has a size.
    var pixelSeconds: Double? { timePixels > 0 && viewLength > 0 ? viewLength / Double(timePixels) : nil }

    /// Scroll pan by `seconds`, keeping the length: moves by whole pixels, carrying the fraction
    /// to the next scroll; stops at the file's ends.
    func pan(by seconds: Double) {
        guard let px = pixelSeconds else { applyView(start: viewStart + seconds, end: viewEnd + seconds); return }
        let total = seconds / px + panRemainder
        let n = (total + (total < 0 ? -1e-9 : 1e-9)).rounded(.towardZero)
        panRemainder = total - n
        shiftView(pixels: n, px: px)
    }

    /// Pan towards the view starting at `start` (drag, scrollbar, follow): the nearest whole
    /// number of pixels.
    func panTo(start: Double) {
        guard let px = pixelSeconds else { applyView(start: start, end: start + viewLength); return }
        panRemainder = 0
        shiftView(pixels: ((start - viewStart) / px).rounded(), px: px)
    }

    private func shiftView(pixels n: Double, px: Double) {
        guard n != 0 else { return }
        let length = viewLength
        let s = viewStart + n * px
        applyView(start: s, end: s + length)
        if abs(viewStart - s) > px * 1e-6 { panRemainder = 0 } // stopped at a limit
    }

    // MARK: Frequency view (spectrogram)

    /// Rows per semitone of the spectrogram (pixels).
    var rowsPerSemitone: Double { SpectrogramConstants.pointsPerSemitone }
    /// Semitones the main pane shows across the time axis.
    var freqSpan: Double { Double(mainCrossLength) / SpectrogramConstants.pointsPerSemitone }

    /// The frequency view's low edge (semitones above A0 − ½), clamped to the range (centred if
    /// the pane is larger) and on whole pixels.
    var freqBottom: Double {
        let span = freqSpan, total = SpectrogramConstants.rangeSemitones
        let rps = rowsPerSemitone
        if span >= total { return (((total - span) / 2) * rps).rounded() / rps }
        let lo = min(max(freqLow ?? (SpectrogramConstants.c4Position - span / 2), 0), total - span)
        return (lo * rps).rounded() / rps
    }

    /// Sets the low edge (clamped).
    func setFreqLow(_ v: Double) {
        let span = freqSpan, total = SpectrogramConstants.rangeSemitones
        guard span < total else { return }
        freqLow = min(max(v, 0), total - span)
    }

    /// Whole file plus margins, amplitude zoom 0 dB.
    func zoomOutFull() {
        setView(start: viewLimits.lower, end: viewLimits.upper)
        amplitudeZoomDB = 0
    }

    func zoomToSelection() {
        guard let s = selection else { return }
        setView(start: s.lowerBound, end: s.upperBound)
    }

    /// Sets the selection, limited to the file. A range with zero length clears it.
    func select(_ a: Double, _ b: Double) {
        let lo = max(min(a, b), 0), hi = min(max(a, b), duration)
        selection = hi > lo ? lo...hi : nil
    }

    /// Toolbar selection indicator.
    var selectionText: String {
        guard let s = selection else { return "–" }
        return "\(formatTime(s.lowerBound)) – \(formatTime(s.upperBound)) (\(formatTime(s.upperBound - s.lowerBound)))"
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    /// Loads the file (blocking). On failure the previously loaded file stays.
    func open(url: URL) {
        do {
            let loaded = try AudioLoader.load(url: url)
            stopPlayback()
            audio = loaded
            player.load(loaded)
            selection = nil
            zoomOutFull()
            playhead = 0
            clearPoint = 0
            lastStart = 0
            timeSignatureDialogPending = false
            timeSignatureDialogShown = false
            hoveredBeatSample = nil
            loadBeats(for: loaded)
            loadID += 1
        } catch {
            errorTitle = "Could not open file"
            errorMessage = "“\(url.lastPathComponent)” could not be opened. \(describe(error))"
        }
    }

    /// Beats from the sidecar file; an invalid file shows an alert and leaves no beats.
    private func loadBeats(for audio: LoadedAudio) {
        do {
            beats = try BeatFile.load(for: audio.url, frameCount: audio.frameCount) ?? []
        } catch {
            beats = []
            errorTitle = "Could not read beats"
            errorMessage = "“\(BeatFile.sidecarURL(for: audio.url).lastPathComponent)”: \(error.localizedDescription) "
                + "The audio file is loaded without beats."
        }
    }
}

/// AVAudioFile reports bad files as bare Core Audio OSStatus codes; turn those into a sentence.
private func describe(_ error: Error) -> String {
    if error is AudioLoadError { return error.localizedDescription }
    let ns = error as NSError
    if ns.domain == NSOSStatusErrorDomain || ns.domain.hasPrefix("com.apple.coreaudio") {
        return "It is not a supported audio file, or it is damaged (error \(fourCC(ns.code)))."
    }
    return error.localizedDescription
}

private func fourCC(_ code: Int) -> String {
    let bytes = (0..<4).map { UInt8(truncatingIfNeeded: code >> (8 * (3 - $0))) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(decoding: bytes, as: UTF8.self) + "'" }
    return String(code)
}

/// Label/value rows of the file information display. Shared by the view and the state dump.
func infoRows(for audio: LoadedAudio) -> [(label: String, value: String)] {
    var rows: [(String, String)] = [
        ("File", audio.fileName),
        ("Duration", formatDuration(audio.duration)),
        ("Sample rate", "\(audio.sampleRate.formatted(.number.precision(.fractionLength(0...2)))) Hz"),
        ("Channels", channelDescription(audio.channelCount)),
        ("Length", "\(audio.frameCount.formatted()) frames"),
    ]
    for (i, s) in audio.channelStats.enumerated() {
        let label = audio.channelCount == 1 ? "Level" : "Level ch \(i + 1)"
        rows.append((label, "peak \(formatDB(s.peakDBFS)), RMS \(formatDB(s.rmsDBFS))"))
    }
    return rows
}

/// m:ss.mmm
func formatTime(_ seconds: Double) -> String {
    let ms = Int((seconds * 1000).rounded())
    return String(format: "%d:%02d.%03d", ms / 60000, ms / 1000 % 60, ms % 1000)
}

private func formatDuration(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    let rest = seconds - Double(minutes * 60)
    return String(format: "%d:%06.3f (%.3f s)", minutes, rest, seconds)
}

private func formatDB(_ db: Double?) -> String {
    guard let db else { return "-∞ dBFS" }
    return String(format: "%.2f dBFS", db)
}

private func channelDescription(_ n: Int) -> String {
    switch n {
    case 1: return "1 (mono)"
    case 2: return "2 (stereo)"
    default: return "\(n)"
    }
}
