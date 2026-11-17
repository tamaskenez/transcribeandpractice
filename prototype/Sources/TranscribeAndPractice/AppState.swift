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
    var selection: ClosedRange<Double>?

    /// Shortest visible range (maximum zoom), in seconds.
    static let minViewLength = 0.1
    /// The visible range may extend this far before the start and after the end of the file.
    static let viewMargin = minViewLength / 2

    private static let orientationKey = "timeOrientation"

    init() {
        orientation = UserDefaults.standard.string(forKey: Self.orientationKey)
            .flatMap(TimeOrientation.init(rawValue:)) ?? .horizontal
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
    var canZoomOutFull: Bool { audio != nil && !isFullView }
    var canZoomToSelection: Bool { audio != nil && selection != nil }

    /// Sets the visible range, applying the limits: length at least minViewLength and at most
    /// the limits' span, keeping the requested center; then shifted inside the limits.
    func setView(start: Double, end: Double) {
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

    /// Moves the visible range by `seconds`, keeping its length; stops at the file's ends.
    func pan(by seconds: Double) {
        setView(start: viewStart + seconds, end: viewEnd + seconds)
    }

    func zoomOutFull() { setView(start: viewLimits.lower, end: viewLimits.upper) }

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
            audio = try AudioLoader.load(url: url)
            selection = nil
            zoomOutFull()
        } catch {
            errorMessage = "“\(url.lastPathComponent)” could not be opened. \(describe(error))"
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
