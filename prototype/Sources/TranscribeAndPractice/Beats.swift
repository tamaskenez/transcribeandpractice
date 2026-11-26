import Foundation

/// A beat marker (see the spec, "Beat markers").
struct Beat: Equatable {
    /// "Beat within bar": `auto` counts from the bar start before it; `start` forces a bar start.
    enum Bar: String { case auto, start }

    /// Identity for the selection (not stored in the file).
    let id: Int
    /// Sample frame index in the file.
    var sample: Int
    /// e.g. "3/4": a time signature change here (nil: continue the previous one).
    var timeSignature: String?
    var bar: Bar

    init(sample: Int, timeSignature: String? = nil, bar: Bar = .auto) {
        id = Beat.makeID()
        self.sample = sample
        self.timeSignature = timeSignature
        self.bar = bar
    }

    /// A forced bar start: set to `start` or changing the time signature.
    var forcesBarStart: Bool { bar == .start || timeSignature != nil }

    nonisolated(unsafe) private static var lastID = 0
    private static func makeID() -> Int { lastID += 1; return lastID }
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

    /// Largest integer ≤ the value.
    var floor: Int { num >= 0 ? num / den : -((-num + den - 1) / den) }
    /// Smallest integer ≥ the value.
    var ceil: Int { num >= 0 ? (num + den - 1) / den : -((-num) / den) }
    var doubleValue: Double { Double(num) / Double(den) }
    var description: String { "\(num)/\(den)" }
}

/// Beat constants (not on the UI yet).
enum BeatConstants {
    /// The note value BPM refers to.
    static let beatNote = Rational(1, 4)
    static let maxReasonableBPM = 240.0
    /// Beats keep at least this far apart (seconds).
    static var minBeatDistance: Double { 60 / maxReasonableBPM }
}

/// Nearest integer, halves away from zero (the Python reference uses the same: floor(x + 0.5)
/// for the non-negative positions here).
@inline(__always) func roundSample(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

/// A time signature, kept as written (4/4 is not 1/1).
struct TimeSignature: Equatable, CustomStringConvertible {
    var num: Int
    var den: Int
    static let standard = TimeSignature(num: 4, den: 4)

    init(num: Int, den: Int) { self.num = num; self.den = den }
    init?(_ s: String?) {
        guard let s, SessionFile.isValidTimeSignature(s) else { return nil }
        let p = s.split(separator: "/")
        num = Int(p[0])!; den = Int(p[1])!
    }

    var description: String { "\(num)/\(den)" }
    /// Beats (of `BeatConstants.beatNote`) in a bar, rounded up.
    var beatsPerBar: Int { Swift.max((Rational(num, den) / BeatConstants.beatNote).ceil, 1) }

    /// A bar of `k` beats, in this signature's denominator if that is exact (6/8 cut to 2 beats:
    /// 4/8), otherwise in the beat note (2/2 cut to 1 beat: 1/4).
    func truncated(toBeats k: Int) -> TimeSignature {
        let bn = BeatConstants.beatNote
        if (k * bn.num * den) % bn.den == 0 { return TimeSignature(num: k * bn.num * den / bn.den, den: den) }
        return TimeSignature(num: k * bn.num, den: bn.den)
    }
}

/// Where a beat is in the bars (see the spec, "Bars").
struct BeatPosition: Equatable {
    /// Bar number: the first forced bar start is bar 1, earlier bars are 0, −1, …
    var bar: Int
    /// 1-based beat within the bar.
    var beatInBar: Int
    /// The time signature in effect (set or inherited).
    var signature: TimeSignature
    /// At a bar start: the bar's effective signature (shortened when the next forced bar start
    /// comes early); nil elsewhere.
    var effective: TimeSignature?

    var isBarStart: Bool { beatInBar == 1 }
}

/// Bars of `beats` (sorted): the default signature is 4/4. Counting starts at the first forced bar
/// start (the first beat if there is none), which is bar 1; its signature (set there, else 4/4)
/// also counts the beats before it, backwards (bars 0, −1, …). From there on each bar lasts its
/// signature's beats per bar, but ends early at the next forced bar start.
func barLayout(_ beats: [Beat]) -> [BeatPosition] {
    let n = beats.count
    guard n > 0 else { return [] }
    let forced = beats.indices.filter { beats[$0].forcesBarStart }
    let first = forced.first ?? 0
    var sig = TimeSignature(beats[first].timeSignature) ?? .standard
    var out = [BeatPosition](repeating: BeatPosition(bar: 1, beatInBar: 1, signature: sig), count: n)
    let p0 = sig.beatsPerBar
    for j in 0..<first {
        let d = first - j - 1 // beats between j and the first bar start
        let beatInBar = p0 - d % p0
        out[j] = BeatPosition(bar: -(d / p0), beatInBar: beatInBar, signature: sig,
                              effective: beatInBar == 1 ? sig : nil)
    }
    var nextForced = forced.makeIterator()
    var nf = nextForced.next() // the next forced bar start at or after i
    var i = first, bar = 1
    while i < n {
        if let ts = TimeSignature(beats[i].timeSignature) { sig = ts }
        while let f = nf, f <= i { nf = nextForced.next() }
        let p = sig.beatsPerBar
        let cut = nf.map { $0 < i + p } ?? false
        let end = Swift.min(cut ? nf! : i + p, n)
        let effective = cut ? sig.truncated(toBeats: end - i) : sig
        for m in i..<end {
            out[m] = BeatPosition(bar: bar, beatInBar: m - i + 1, signature: sig, effective: m == i ? effective : nil)
        }
        bar += 1
        i = end
    }
    return out
}

/// "1st", "2nd", "3rd", "4th", … "11th", "21st".
func ordinal(_ n: Int) -> String {
    let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
    return "\(n)\(suffix)"
}
