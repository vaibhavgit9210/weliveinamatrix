import Foundation
import Security

/// mulberry32, the same generator the other toys here use. Seeded from the
/// system CSPRNG at launch, so nothing repeats, but a seed can be pinned when
/// a run needs reproducing.
struct Mulberry32 {
    private var a: UInt32

    init(seed: UInt32) { a = seed }

    mutating func next() -> Double {
        a = a &+ 0x6D2B79F5
        var t = (a ^ (a >> 15)) &* (a | 1)
        t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }

    /// Uniform in [lo, hi).
    mutating func next(_ lo: Double, _ hi: Double) -> Double {
        lo + next() * (hi - lo)
    }
}

enum Entropy {
    static func seed() -> UInt32 {
        var v: UInt32 = 0
        let ok = withUnsafeMutableBytes(of: &v) { buf in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!) == errSecSuccess
        }
        if !ok || v == 0 {
            v = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)) ^ 0x9E37_79B9
        }
        return v
    }
}

/// One label in the overlay.
///
/// A class rather than a struct because links hold on to two of them, the way
/// the web build keeps two object references.
final class Tracker {
    enum Kind { case tag, box, fill }

    var x: Double
    var y: Double
    let id: Int
    let vx: Double
    let vy: Double
    var age: Double = 0
    let ttl: Double
    let size: Double
    let kind: Kind
    let w: Double
    let h: Double
    let teal: Bool
    var dead = false

    init(x: Double, y: Double, id: Int, vx: Double, vy: Double, ttl: Double,
         size: Double, kind: Kind, w: Double, h: Double, teal: Bool) {
        self.x = x; self.y = y; self.id = id
        self.vx = vx; self.vy = vy
        self.ttl = ttl; self.size = size; self.kind = kind
        self.w = w; self.h = h; self.teal = teal
    }

    /// Fades in over six frames and out over the last twenty.
    var fade: Double { min(1, min((ttl - age) / 20, age / 6)) }
}

struct Link {
    let a: Tracker
    let b: Tracker
}

/// The tracker cloud, ported line for line from `index.html`. There is no
/// machine vision in here and no drawing either: it is handed a luminance grid
/// and leaves `trackers` and `links` for the scene to read.
///
/// Coordinates keep the web build's convention — points, origin top left, y
/// growing *downward* — so this file reads against the original. `TrackerScene`
/// flips the sign once when it places a node.
final class TrackerSim {

    static let maxTrackers = 450
    static let maxLinks = 46
    /// motion-grid width in cells
    static let gridWidth = 176

    private(set) var trackers: [Tracker] = []
    private(set) var links: [Link] = []

    /// The area the grid covers, in points, and the grid that covers it.
    private(set) var width: Double = 1
    private(set) var height: Double = 1
    private(set) var gridHeight = 24
    private(set) var cell: Double = 1

    private var prevLum: [UInt8]?
    private var nextId: Int
    private var rng: Mulberry32

    init(seed: UInt32 = Entropy.seed()) {
        var r = Mulberry32(seed: seed)
        // ids only ever count up, like the real thing
        nextId = 300 + Int(r.next() * 30000)
        rng = r
    }

    /// Grid height for a given view aspect, so the cells stay square.
    static func gridHeight(forWidth w: Double, height h: Double) -> Int {
        guard w > 0, h > 0 else { return 24 }
        return max(24, Int((Double(gridWidth) * h / w).rounded()))
    }

    func resize(width w: Double, height h: Double) {
        guard w > 0, h > 0 else { return }
        width = w
        height = h
        gridHeight = Self.gridHeight(forWidth: w, height: h)
        cell = w / Double(Self.gridWidth)
        prevLum = nil
    }

    // MARK: - One frame

    /// `lum` is `gridWidth * gridHeight` luminance samples, row major, taken
    /// from the part of the camera frame that is actually on screen.
    func step(lum: [UInt8]) {
        let gw = Self.gridWidth
        let gh = gridHeight
        let n = gw * gh
        guard lum.count == n, n > gw + 1 else { return }

        // 1. diff against the last frame. The neighbour confirmation is what
        //    keeps sensor noise on a flat wall from reading as movement.
        var motion: [Int] = []
        var strong: [Int] = []
        var feats: [Int] = []
        if let prev = prevLum, prev.count == n {
            for i in 0..<(n - gw - 1) {
                let d = abs(Int(lum[i]) - Int(prev[i]))
                if d > 30 && (abs(Int(lum[i + 1]) - Int(prev[i + 1])) > 16
                              || abs(Int(lum[i + gw]) - Int(prev[i + gw])) > 16) {
                    motion.append(i)
                    if d > 70 { strong.append(i) }
                }
            }
        }
        // static "feature" points (edges), so a calm room still gets labels
        if motion.count < 30 {
            var i = 0
            while i < n - gw - 1 {
                if abs(Int(lum[i]) - Int(lum[i + 1])) + abs(Int(lum[i]) - Int(lum[i + gw])) > 52 {
                    feats.append(i)
                }
                i += 3
            }
        }
        prevLum = lum

        // 2. population control: density follows the amount of motion
        let want = min(Self.maxTrackers, 26 + motion.count * 3)
        var spawns = min(16, max(0, want - trackers.count))
        // coarse grid: one label per region, so they scatter instead of piling up
        var occupied = Set<Int>()
        let osz = max(1e-6, width / 32)
        func okey(_ x: Double, _ y: Double) -> Int { Int(x / osz) + 4096 * Int(y / osz) }
        for t in trackers { occupied.insert(okey(t.x, t.y)) }
        while spawns > 0 {
            spawns -= 1
            var i: Int
            if !strong.isEmpty && rng.next() < 0.65 {
                i = strong[Int(rng.next() * Double(strong.count))]
            } else if !motion.isEmpty {
                i = motion[Int(rng.next() * Double(motion.count))]
            } else if !feats.isEmpty {
                i = feats[Int(rng.next() * Double(feats.count))]
            } else {
                i = Int(rng.next() * Double(n))
            }
            let x = (Double(i % gw) + rng.next()) * cell
            let y = (Double(i / gw) + rng.next()) * cell
            let k = okey(x, y)
            if occupied.contains(k) { continue }
            occupied.insert(k)
            spawn(x: x, y: y)
        }

        // 3. trackers whose neighbourhood went still decay fast, so the cloud
        //    clings to whatever is moving
        let motionSet = Set(motion)
        for t in trackers {
            let ci = Int(t.x / cell) + gw * Int(t.y / cell)
            if !(motionSet.contains(ci) || motionSet.contains(ci - 1) || motionSet.contains(ci + 1)
                 || motionSet.contains(ci - gw) || motionSet.contains(ci + gw)) {
                t.age += 3
            }
        }
        trackers = trackers.filter { t in
            t.age += 1
            if t.age >= t.ttl || t.x < -80 || t.x > width + 80 || t.y < -40 || t.y > height + 40 {
                t.dead = true
            }
            return !t.dead
        }
        if trackers.count > Self.maxTrackers {
            let extra = trackers.count - Self.maxTrackers
            for t in trackers[0..<extra] { t.dead = true }
            trackers.removeFirst(extra)
        }
        links = links.filter { !$0.a.dead && !$0.b.dead }

        // 4. the nervous jitter is the whole aesthetic
        for t in trackers {
            t.x += t.vx + (rng.next() - 0.5) * 0.5
            t.y += t.vy + (rng.next() - 0.5) * 0.5
        }
    }

    /// Draws in the same order as the object literal in the web build, so the
    /// two make the same choices from the same stream.
    private func spawn(x: Double, y: Double) {
        let r = rng.next()
        let t = Tracker(
            x: x, y: y, id: nextId,
            vx: (rng.next() - 0.5) * 0.25,
            vy: (rng.next() - 0.5) * 0.25,
            ttl: 40 + rng.next() * 150,
            size: 9 + rng.next() * 4,
            kind: r < 0.78 ? .tag : r < 0.96 ? .box : .fill,
            w: 14 + rng.next() * 60,
            h: 8 + rng.next() * 40,
            teal: rng.next() < 0.05
        )
        nextId += 1
        trackers.append(t)
        // occasionally wire the newcomer to an older tracker — the web of lines
        if links.count < Self.maxLinks && trackers.count > 4 && rng.next() < 0.12 {
            links.append(Link(a: t, b: trackers[Int(rng.next() * Double(trackers.count - 1))]))
        }
    }
}
