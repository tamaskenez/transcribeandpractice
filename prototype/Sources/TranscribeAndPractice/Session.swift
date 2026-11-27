import Foundation

/// Time signature denominators offered and accepted.
let timeSignatureDenominators = [1, 2, 4, 8, 16, 32, 64, 128]

struct SessionFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The session file next to the audio file (milestone 13; replaces the beats sidecar): the
/// beats and the notes. Only the current format is read; anything else is rejected.
///
///     {"beats": [{"sample": 22050, "firstBeat": "auto"|"start", "timeSignature": "3/4"?}, …],
///      "notes": [{"start": {"beat": 3, "tau": "1/2", "pitch": 60},
///                 "end": {"beat": 4, "tau": "0/1", "pitch": 62}}, …]}
///
/// Beats are in ascending sample order; notes refer to them by index. `tau` is an exact fraction
/// "n/d" with 0 ≤ tau < 1 (tau > 0 needs a next beat); pitches are MIDI note numbers.
enum SessionFile {
    /// `song.mp3` → `song.mp3.session.json`.
    static func url(for audio: URL) -> URL {
        audio.deletingLastPathComponent().appendingPathComponent(audio.lastPathComponent + ".session.json")
    }

    /// The session of the audio file; nil if there is no session file.
    static func load(for audio: URL, frameCount: Int) throws -> (beats: [Beat], notes: [Note])? {
        let url = url(for: audio)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw SessionFileError(message: error.localizedDescription) }
        return try parse(data, frameCount: frameCount)
    }

    private static func fail(_ m: String) -> SessionFileError { SessionFileError(message: m) }

    static func parse(_ data: Data, frameCount: Int) throws -> (beats: [Beat], notes: [Note]) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw fail("It is not valid JSON.")
        }
        guard let root = json as? [String: Any], let rawBeats = root["beats"] as? [Any], let rawNotes = root["notes"] as? [Any] else {
            throw fail("It is not a session: a JSON object with “beats” and “notes” arrays.")
        }
        let beats = try parseBeats(rawBeats, frameCount: frameCount)
        let notes = try rawNotes.enumerated().map { try parseNote($1, number: $0 + 1, beats: beats) }
        return (beats, notes)
    }

    private static func wholeNumber(_ v: Any?) -> Int? {
        guard let num = v as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(),
              num.doubleValue == num.doubleValue.rounded(), abs(num.doubleValue) < 1e15 else { return nil }
        return num.intValue
    }

    private static func parseBeats(_ raw: [Any], frameCount: Int) throws -> [Beat] {
        var beats: [Beat] = []
        for (i, r) in raw.enumerated() {
            let n = "Beat \(i + 1)"
            guard let e = r as? [String: Any] else { throw fail("\(n) is not an object.") }
            guard e["sample"] != nil else { throw fail("\(n): “sample” is missing.") }
            guard let sample = wholeNumber(e["sample"]) else { throw fail("\(n): “sample” must be a whole number.") }
            guard sample >= 0, sample < frameCount else {
                throw fail("\(n): sample \(sample) is outside the file (0 … \(frameCount - 1)).")
            }
            guard e["firstBeat"] != nil else { throw fail("\(n): “firstBeat” is missing.") }
            guard let bar = (e["firstBeat"] as? String).flatMap(Beat.Bar.init(rawValue:)) else {
                throw fail("\(n): “firstBeat” must be “auto” or “start”.")
            }
            var timeSignature: String?
            if let rawTS = e["timeSignature"], !(rawTS is NSNull) {
                guard let ts = rawTS as? String, isValidTimeSignature(ts) else {
                    throw fail("\(n): “timeSignature” must look like “4/4” (denominator 1, 2, 4 … 128).")
                }
                timeSignature = ts
            }
            if let last = beats.last, sample <= last.sample {
                throw fail("\(n): the beats must be in ascending sample order (sample \(sample) after \(last.sample)).")
            }
            beats.append(Beat(sample: sample, timeSignature: timeSignature, bar: bar))
        }
        return beats
    }

    private static func parsePitch(_ v: Any?, _ what: String) throws -> Float {
        guard let num = v as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite,
              num.doubleValue >= 0, num.doubleValue <= 127 else { throw fail("\(what) must be a MIDI pitch (0 … 127).") }
        return num.floatValue
    }

    /// A grid location: beat index and "n/d" tau.
    private static func parseLoc(_ e: [String: Any], _ what: String, beats: [Beat]) throws -> (GridLoc, Rational) {
        guard let i = wholeNumber(e["beat"]), i >= 0, i < beats.count else {
            throw fail("\(what): “beat” must be a beat index (0 … \(beats.count - 1)).")
        }
        guard let s = e["tau"] as? String, s.split(separator: "/").count == 2, let tau = Rational(s),
              Rational(0, 1) <= tau, tau < Rational(1, 1) else {
            throw fail("\(what): “tau” must be a fraction “n/d” from 0 up to (not including) 1.")
        }
        if tau > Rational(0, 1), i + 1 >= beats.count { throw fail("\(what): “tau” above 0 needs a beat after beat \(i).") }
        return (GridLoc(beat: beats[i].id, tau: tau), Rational(i, 1) + tau)
    }

    private static func parseNote(_ raw: Any, number: Int, beats: [Beat]) throws -> Note {
        let n = "Note \(number)"
        guard let e = raw as? [String: Any] else { throw fail("\(n) is not an object.") }
        guard let start = e["start"] as? [String: Any] else { throw fail("\(n): “start” is missing.") }
        guard let end = e["end"] as? [String: Any] else { throw fail("\(n): “end” is missing.") }
        let (l0, p0) = try parseLoc(start, "\(n), start", beats: beats)
        let (l1, p1) = try parseLoc(end, "\(n), end", beats: beats)
        if p1 <= p0 { throw fail("\(n): the end is not after the start.") }
        return Note(start: l0, startPitch: try parsePitch(start["pitch"], "\(n), start: “pitch”"),
                    end: l1, endPitch: try parsePitch(end["pitch"], "\(n), end: “pitch”"))
    }

    static func isValidTimeSignature(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let n = Int(parts[0]), let d = Int(parts[1]) else { return false }
        return n >= 1 && timeSignatureDenominators.contains(d)
    }

    /// The session's JSON (`timeSignature` left out when absent). Notes whose beats are gone are left out.
    static func encode(beats: [Beat], notes: [Note]) throws -> Data {
        let index = Dictionary(uniqueKeysWithValues: beats.enumerated().map { ($1.id, $0) })
        func loc(_ l: GridLoc) -> [String: Any]? { index[l.beat].map { ["beat": $0, "tau": "\(l.tau.num)/\(l.tau.den)"] } }
        let b: [[String: Any]] = beats.map { b in
            var d: [String: Any] = ["sample": b.sample, "firstBeat": b.bar.rawValue]
            if let ts = b.timeSignature { d["timeSignature"] = ts }
            return d
        }
        let n: [[String: Any]] = notes.compactMap { n in
            guard var start = loc(n.start), var end = loc(n.end) else { return nil }
            start["pitch"] = Double(n.startPitch)
            end["pitch"] = Double(n.endPitch)
            return ["start": start, "end": end]
        }
        return try JSONSerialization.data(withJSONObject: ["beats": b, "notes": n], options: [.prettyPrinted, .sortedKeys])
    }
}
