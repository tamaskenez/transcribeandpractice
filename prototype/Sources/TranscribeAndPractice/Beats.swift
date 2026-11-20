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
                    throw BeatFileError(message: "\(n): “timeSignature” must look like “4/4” (denominator 1, 2, 4 … 64).")
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
        return n >= 1 && [1, 2, 4, 8, 16, 32, 64].contains(d)
    }
}
