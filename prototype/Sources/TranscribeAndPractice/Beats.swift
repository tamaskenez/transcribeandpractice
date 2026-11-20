import Foundation

/// A beat marker (see the spec, "Beat markers").
struct Beat: Equatable {
    enum Source: String { case placed, computed }
    enum FirstBeat: String { case no, placed, computed }

    /// Sample frame index in the file.
    var sample: Int
    var source: Source
    /// e.g. "3/4"; nil inherits the previous beat's.
    var timeSignature: String?
    var firstBeat: FirstBeat

    var isDownbeat: Bool { firstBeat != .no }
}

struct BeatFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum BeatFile {
    /// `song.mp3` → `song.mp3.beats.json`, next to the audio file.
    static func sidecarURL(for audio: URL) -> URL {
        audio.deletingLastPathComponent().appendingPathComponent(audio.lastPathComponent + ".beats.json")
    }

    /// The beats of the sidecar file, sorted; nil if there is no sidecar file.
    static func load(for audio: URL, frameCount: Int) throws -> [Beat]? {
        let url = sidecarURL(for: audio)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw BeatFileError(message: error.localizedDescription) }
        return try parse(data, frameCount: frameCount)
    }

    static func parse(_ data: Data, frameCount: Int) throws -> [Beat] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw BeatFileError(message: "It is not valid JSON.")
        }
        guard let array = json as? [Any], let entries = array as? [[String: Any]] else {
            throw BeatFileError(message: "It is not a JSON array of beat objects.")
        }
        var beats: [Beat] = []
        for (i, e) in entries.enumerated() {
            let n = "Beat \(i + 1)"
            guard let rawSample = e["sample"] else { throw BeatFileError(message: "\(n): “sample” is missing.") }
            guard let num = rawSample as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(),
                  num.doubleValue == num.doubleValue.rounded(), abs(num.doubleValue) < 1e15
            else { throw BeatFileError(message: "\(n): “sample” must be a whole number.") }
            let sample = num.intValue
            guard sample >= 0, sample < frameCount else {
                throw BeatFileError(message: "\(n): sample \(sample) is outside the file (0 … \(frameCount - 1)).")
            }
            guard let rawSource = e["source"] else { throw BeatFileError(message: "\(n): “source” is missing.") }
            guard let s = rawSource as? String, let source = Beat.Source(rawValue: s) else {
                throw BeatFileError(message: "\(n): “source” must be “placed” or “computed”.")
            }
            guard let rawFirst = e["firstBeat"] else { throw BeatFileError(message: "\(n): “firstBeat” is missing.") }
            guard let f = rawFirst as? String, let firstBeat = Beat.FirstBeat(rawValue: f) else {
                throw BeatFileError(message: "\(n): “firstBeat” must be “no”, “placed” or “computed”.")
            }
            var timeSignature: String?
            if let rawTS = e["timeSignature"], !(rawTS is NSNull) {
                guard let ts = rawTS as? String, isValidTimeSignature(ts) else {
                    throw BeatFileError(message: "\(n): “timeSignature” must look like “4/4” (denominator 1, 2, 4 … 128).")
                }
                timeSignature = ts
            }
            beats.append(Beat(sample: sample, source: source, timeSignature: timeSignature, firstBeat: firstBeat))
        }
        beats.sort { $0.sample < $1.sample }
        for (a, b) in zip(beats, beats.dropFirst()) where a.sample == b.sample {
            throw BeatFileError(message: "Two beats are at sample \(a.sample).")
        }
        return beats
    }

    static func isValidTimeSignature(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let n = Int(parts[0]), let d = Int(parts[1]) else { return false }
        return n >= 1 && timeSignatureDenominators.contains(d)
    }
}

/// An exact fraction, kept reduced with a positive denominator.
struct Rational: Equatable, Comparable, CustomStringConvertible {
    let num: Int
    let den: Int

    init(_ num: Int, _ den: Int) {
        precondition(den != 0, "zero denominator")
        let g = Swift.max(Rational.gcd(abs(num), abs(den)), 1)
        let sign = den < 0 ? -1 : 1
        self.num = sign * num / g
        self.den = sign * den / g
    }

    /// "n/d" (e.g. a time signature), nil if malformed.
    init?(_ s: String) {
        let p = s.split(separator: "/")
        guard p.count == 2, let n = Int(p[0]), let d = Int(p[1]), d != 0 else { return nil }
        self.init(n, d)
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    static func + (a: Rational, b: Rational) -> Rational { Rational(a.num * b.den + b.num * a.den, a.den * b.den) }
    static func - (a: Rational, b: Rational) -> Rational { Rational(a.num * b.den - b.num * a.den, a.den * b.den) }
    static func * (a: Rational, b: Rational) -> Rational { Rational(a.num * b.num, a.den * b.den) }
    static func / (a: Rational, b: Rational) -> Rational { Rational(a.num * b.den, a.den * b.num) }
    static func < (a: Rational, b: Rational) -> Bool { a.num * b.den < b.num * a.den }

    /// Smallest integer ≥ the value.
    var ceil: Int { num >= 0 ? (num + den - 1) / den : -((-num) / den) }
    var doubleValue: Double { Double(num) / Double(den) }
    var description: String { "\(num)/\(den)" }
}

/// Beat constants (not on the UI yet).
enum BeatConstants {
    /// The note value BPM refers to.
    static let beatNote = Rational(1, 4)
    static let minReasonableBPM = 30.0
    static let maxReasonableBPM = 240.0
    /// Placed beats keep at least this far apart (seconds).
    static var minPlacedDistance: Double { 60 / maxReasonableBPM }
}

/// Nearest integer, halves away from zero (the Python reference uses the same: floor(x + 0.5)
/// for the non-negative positions here).
@inline(__always) func roundSample(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

/// The spec's recomputation: drops the computed beats and the computed downbeats, inserts
/// computed beats between and after the placed beats, then marks the computed downbeats.
func recomputeBeats(_ beats: [Beat], sampleRate sr: Double, frameCount: Int) -> [Beat] {
    let placed = beats.filter { $0.source == .placed }.map { b -> Beat in
        var b = b
        if b.firstBeat == .computed { b.firstBeat = .no }
        return b
    }
    var out: [Beat] = []
    if placed.count >= 2 {
        var current: Double?
        for (b1, b2) in zip(placed, placed.dropFirst()) {
            out.append(b1)
            let dt = Double(b2.sample - b1.sample) / sr
            if let cur = current {
                // The real-valued optimum is cur·dt/60 intervals; the best integer is next to it.
                let ideal = cur * dt / 60
                var best = 0, bestErr = Double.infinity
                for n in Swift.max(Int(ideal.rounded(.down)) - 1, 0)...(Int(ideal.rounded(.up)) + 1) {
                    let result = Double(n + 1) * 60 / dt
                    let err = abs(log(cur / result))
                    if err < bestErr { best = n; bestErr = err }
                }
                for j in stride(from: 1, through: best, by: 1) {
                    let s = roundSample(Double(b1.sample) + Double(j) * Double(b2.sample - b1.sample) / Double(best + 1))
                    out.append(Beat(sample: s, source: .computed, timeSignature: nil, firstBeat: .no))
                }
                current = Double(best + 1) * 60 / dt
            } else {
                let result = 60 / dt
                if result >= BeatConstants.minReasonableBPM { current = result }
            }
        }
        let last = placed[placed.count - 1]
        out.append(last)
        if let cur = current {
            var k = 1
            while true {
                let s = roundSample(Double(last.sample) + Double(k) * 60 / cur * sr)
                if s >= frameCount { break }
                out.append(Beat(sample: s, source: .computed, timeSignature: nil, firstBeat: .no))
                k += 1
            }
        }
    } else {
        out = placed
    }
    // Bars.
    var signature: Rational?
    var beatInBar = 1
    for i in out.indices {
        if let ts = out[i].timeSignature { signature = Rational(ts) }
        guard let sig = signature else { continue }
        let perBar = Swift.max((sig / BeatConstants.beatNote).ceil, 1)
        if out[i].firstBeat == .placed {
            beatInBar = 1
        } else if beatInBar == 1 {
            out[i].firstBeat = .computed
        }
        beatInBar = beatInBar % perBar + 1
    }
    return out
}

extension BeatFile {
    /// The sidecar's JSON for `beats` (`timeSignature` left out when absent).
    static func encode(_ beats: [Beat]) throws -> Data {
        let array: [[String: Any]] = beats.map { b in
            var d: [String: Any] = ["sample": b.sample, "source": b.source.rawValue, "firstBeat": b.firstBeat.rawValue]
            if let ts = b.timeSignature { d["timeSignature"] = ts }
            return d
        }
        return try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys])
    }
}

let timeSignatureDenominators = [1, 2, 4, 8, 16, 32, 64, 128]
