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
