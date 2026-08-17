import Foundation
import Security

/// mulberry32, the same generator the web build now uses, so a run can be pinned
/// to a seed and the two builds can be compared draw for draw.
struct Mulberry32 {
    private var a: UInt32

    init(seed: UInt32) { a = seed }

    mutating func next() -> Double {
        a = a &+ 0x6D2B79F5
        var t = (a ^ (a >> 15)) &* (a | 1)
        t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }

    mutating func next(_ lo: Double, _ hi: Double) -> Double { lo + next() * (hi - lo) }
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

/// Every number the detector and the tracker use. Kept in one place because the
/// web build has the same block, and the two have to stay in step.
enum CFG {
    static let gridWidth = 176          // ceiling; the grid is sized to a budget
    static let gridMin = 96
    static let cellBudget = 30000

    static let motion = 30, motionNbr = 16
    static let edge = 52

    static let skinCbLo = 77.0, skinCbHi = 127.0
    static let skinCrLo = 133.0, skinCrHi = 173.0
    static let skinLumaLo = 40.0, skinLumaHi = 240.0, skinDiff = 14.0
    static let skinMinArea = 40

    static let subjMinSide = 9
    static let subjMinMotion = 26
    static let subjSkinFrac = 0.18
    static let faceAspectLo = 0.55, faceAspectHi = 1.9
    static let handFrac = 0.5

    static let moteMaxSide = 7
    static let swarmMin = 5
    static let spotRadius = 4
    static let spotContrast = 20.0
    static let spotAreaFrac = 0.08
    static let spotMaxCount = 90

    static let beamLuma: UInt8 = 96      // bright...
    static let beamTexture = 26          // ...and soft: a shaft has no detail in it
    static let beamAreaFrac = 0.045      // ...and a band, not the whole room
    static let beamAreaMax = 0.55
    static let beamElong = 2.8           // long and thin; a lit window is stubby
    static let beamContrast = 34.0       // and only visible because the rest is dark
    static let beamCapture = 0.45

    static let maxTracks = 72
    static let maxMotes = 460
    static let maxLinks = 44

    static func trackMiss(_ mode: SubjectMode) -> Int {
        switch mode {
        case .living: return 12
        case .swarm: return 4
        case .beam: return 8
        case .object: return 8
        case .none: return 0
        }
    }

    /// The grid for a view of this shape: as many cells as the budget allows, so
    /// a tall phone frame does not cost three times a wide one.
    static func grid(forWidth w: Double, height h: Double) -> (Int, Int) {
        guard w > 0, h > 0 else { return (gridMin, 24) }
        let gw = max(gridMin, min(gridWidth, Int((Double(cellBudget) * w / h).squareRoot().rounded())))
        return (gw, max(24, Int((Double(gw) * h / w).rounded())))
    }
}

enum SubjectMode: String {
    case none, living, swarm, beam, object

    var readout: String {
        switch self {
        case .none: return "NO SUBJECT"
        case .living: return "LIVING"
        case .swarm: return "SWARM"
        case .beam: return "TYNDALL"
        case .object: return "OBJECT"
        }
    }
}

/// One connected component of a mask: a thing that moved, a patch of skin, a
/// shaft of light.
struct Mass {
    var area = 0
    var cx = 0.0, cy = 0.0
    var minx = 0, maxx = 0, miny = 0, maxy = 0
    var w = 0, h = 0
    var motion = 0
    var skinFrac = 0.0
    var lumaMean = 0.0
    var elong = 1.0
    var cells: [Int]? = nil
    var isFlesh = false
}

/// A lock. Persistent id, class name, and a box eased onto the measurement.
final class Track {
    let id: Int
    var cls: String
    var x: Double, y: Double, w: Double, h: Double
    var conf: Double
    var matched = false
    var miss = 0
    var age = 0
    var dead = false
    let teal: Bool
    let phase: Double

    init(id: Int, cls: String, x: Double, y: Double, w: Double, h: Double,
         conf: Double, teal: Bool, phase: Double) {
        self.id = id; self.cls = cls
        self.x = x; self.y = y; self.w = w; self.h = h
        self.conf = conf; self.teal = teal; self.phase = phase
    }
}

/// One number in the flood. Either penned inside a lock, or loose inside the beam.
final class Mote {
    enum Kind { case tag, box, fill }

    let id: Int
    let owner: Track?
    var ox = 0.0, oy = 0.0
    var x: Double, y: Double
    let vx: Double, vy: Double
    var age = 0.0
    let ttl: Double
    let size: Double
    let kind: Kind
    let w: Double, h: Double
    let teal: Bool
    var dead = false

    init(id: Int, owner: Track?, x: Double, y: Double, vx: Double, vy: Double,
         ttl: Double, size: Double, kind: Kind, w: Double, h: Double, teal: Bool) {
        self.id = id; self.owner = owner
        self.x = x; self.y = y; self.vx = vx; self.vy = vy
        self.ttl = ttl; self.size = size; self.kind = kind
        self.w = w; self.h = h; self.teal = teal
    }

    var fade: Double { min(1, min((ttl - age) / 18, age / 5)) }
}

struct Link {
    let a: Track
    let b: Track
}

/// Finds the one kind of subject a frame is about, locks onto every instance of
/// it, and floods those locks with numbers. Ported from `index.html`; there is no
/// drawing in here.
///
/// Coordinates keep the web build's convention — points, origin top left, y
/// growing downward — so this file reads against the original. `TrackerScene`
/// flips the sign once, when it places a node.
final class TrackerSim {

    private(set) var tracks: [Track] = []
    private(set) var motes: [Mote] = []
    private(set) var links: [Link] = []
    private(set) var mode: SubjectMode = .none
    private(set) var chaos = 0.0

    private(set) var width = 1.0, height = 1.0
    private(set) var gridWidth = CFG.gridMin, gridHeight = 24
    private(set) var cell = 1.0

    /// The last frame's luminance, kept so the scene can pick its ink.
    private(set) var luma: [UInt8] = []
    /// The beam's cells, when a beam is what is being tracked.
    private(set) var beamCells: [Int] = []

    private var skin: [UInt8] = []
    private var prev: [UInt8] = []
    private var prevReady = false
    private var mot: [UInt8] = []
    private var dil: [UInt8] = [], dilB: [UInt8] = []
    private var brightM: [UInt8] = [], spotM: [UInt8] = [], inBeam: [UInt8] = []
    private var lab: [Int32] = [], stack: [Int32] = []
    private var integral: [UInt32] = []
    private var motCount = 0
    private var frameNo = 0

    private var pendingMode: SubjectMode? = nil
    private var pendingCount = 0
    private var nextId: Int
    private var rng: Mulberry32

    var frameCount: Int { frameNo }

    init(seed: UInt32 = Entropy.seed()) {
        var r = Mulberry32(seed: seed)
        nextId = 300 + Int(r.next() * 30000)
        rng = r
    }

    func resize(width w: Double, height h: Double) {
        guard w > 0, h > 0 else { return }
        width = w
        height = h
        (gridWidth, gridHeight) = CFG.grid(forWidth: w, height: h)
        cell = w / Double(gridWidth)
        let n = gridWidth * gridHeight
        luma = [UInt8](repeating: 0, count: n)
        skin = [UInt8](repeating: 0, count: n)
        prev = [UInt8](repeating: 0, count: n)
        mot = [UInt8](repeating: 0, count: n)
        dil = [UInt8](repeating: 0, count: n)
        dilB = [UInt8](repeating: 0, count: n)
        brightM = [UInt8](repeating: 0, count: n)
        spotM = [UInt8](repeating: 0, count: n)
        inBeam = [UInt8](repeating: 0, count: n)
        lab = [Int32](repeating: 0, count: n)
        stack = [Int32](repeating: 0, count: n)
        integral = [UInt32](repeating: 0, count: (gridWidth + 1) * (gridHeight + 1))
        prevReady = false
        tracks = []; motes = []; links = []; beamCells = []
        mode = .none
    }

    /// Forgets the previous frame without dropping the locks, for the cut between
    /// the two cameras.
    func forgetPreviousFrame() { prevReady = false }

    // MARK: - One frame

    func step(luma newLuma: [UInt8], skin newSkin: [UInt8]) {
        let n = gridWidth * gridHeight
        guard newLuma.count == n, newSkin.count == n else { return }
        frameNo += 1
        luma = newLuma
        skin = newSkin

        motionPass()
        let state = classify()
        let settled = debounce(state.mode)
        if settled != mode {
            // Only one class of subject is ever tracked, so a change of class
            // starts clean rather than leaving old locks under new labels.
            tracks = []; motes = []; links = []
            mode = settled
        }
        let fresh = state.mode == mode
        beamCells = mode == .beam ? (state.beam?.cells ?? []) : []

        switch mode {
        case .living where fresh:
            var biggestSkin = 0
            for m in state.subjects where m.skinFrac >= CFG.subjSkinFrac {
                biggestSkin = max(biggestSkin, m.area)
            }
            update(targets: state.subjects.map { target($0, className($0, biggestSkin: biggestSkin)) },
                   maxMiss: CFG.trackMiss(.living))
        case .swarm where fresh:
            update(targets: state.subjects.map { target($0, "MOTE") }, maxMiss: CFG.trackMiss(.swarm))
        case .object where fresh:
            update(targets: state.subjects.map { target($0, "OBJECT") }, maxMiss: CFG.trackMiss(.object))
        default:
            update(targets: [], maxMiss: CFG.trackMiss(mode))
        }
        updateMotes(beam: state.beam)

        prev = luma
        prevReady = true
    }

    /// A single odd frame should not restart the tracking, so a new class has to
    /// hold for a few frames before the display follows it.
    private func debounce(_ candidate: SubjectMode) -> SubjectMode {
        if candidate == mode { pendingMode = nil; pendingCount = 0; return mode }
        if candidate == pendingMode { pendingCount += 1 } else { pendingMode = candidate; pendingCount = 1 }
        if pendingCount >= (mode == .none ? 1 : 3) {
            pendingMode = nil; pendingCount = 0
            return candidate
        }
        return mode
    }

    // MARK: - Masks

    private func motionPass() {
        let gw = gridWidth, n = gw * gridHeight
        for i in 0..<n { mot[i] = 0 }
        motCount = 0
        guard prevReady else { return }
        for i in 0..<(n - gw - 1) {
            let d = abs(Int(luma[i]) - Int(prev[i]))
            // neighbour confirmation, or sensor noise on a flat wall reads as
            // movement
            if d > CFG.motion && (abs(Int(luma[i + 1]) - Int(prev[i + 1])) > CFG.motionNbr
                                  || abs(Int(luma[i + gw]) - Int(prev[i + gw])) > CFG.motionNbr) {
                mot[i] = 1
                motCount += 1
            }
        }
    }

    /// Bright and *smooth*: a shaft of light is the one thing in a room with a lot
    /// of luminance and almost no detail in it.
    private func lightPass() -> Int {
        let gw = gridWidth, gh = gridHeight
        for i in 0..<(gw * gh) { brightM[i] = 0 }
        var count = 0
        for y in 1..<(gh - 1) {
            for x in 1..<(gw - 1) {
                let i = y * gw + x
                let v = luma[i]
                if v < CFG.beamLuma { continue }
                let tex = abs(Int(v) - Int(luma[i + 1])) + abs(Int(v) - Int(luma[i - 1]))
                        + abs(Int(v) - Int(luma[i + gw])) + abs(Int(v) - Int(luma[i - gw]))
                if tex < CFG.beamTexture { brightM[i] = 1; count += 1 }
            }
        }
        return count
    }

    /// Small high-contrast grains, moving or not. A bee crossing frame differences
    /// beautifully; an ant crawling, or dust hanging in still air, barely moves
    /// between frames and would never be found by motion alone. A summed-area
    /// table makes the local mean one pass.
    private func spotPass() -> Int {
        let gw = gridWidth, gh = gridHeight, w1 = gw + 1
        for x in 0...gw { integral[x] = 0 }
        for y in 0..<gh {
            var row: UInt32 = 0
            integral[(y + 1) * w1] = 0
            for x in 0..<gw {
                row += UInt32(luma[y * gw + x])
                integral[(y + 1) * w1 + x + 1] = integral[y * w1 + x + 1] + row
            }
        }
        for i in 0..<(gw * gh) { spotM[i] = 0 }
        let r = CFG.spotRadius
        let window = Double((2 * r + 1) * (2 * r + 1))
        var count = 0
        guard gh > 2 * r, gw > 2 * r else { return 0 }
        for y in r..<(gh - r) {
            for x in r..<(gw - r) {
                let x0 = x - r, y0 = y - r, x1 = x + r + 1, y1 = y + r + 1
                let sum = Double(integral[y1 * w1 + x1]) - Double(integral[y0 * w1 + x1])
                        - Double(integral[y1 * w1 + x0]) + Double(integral[y0 * w1 + x0])
                if abs(Double(luma[y * gw + x]) - sum / window) > CFG.spotContrast {
                    spotM[y * gw + x] = 1
                    count += 1
                }
            }
        }
        return count
    }

    /// Grow a mask so a subject's separate flickers join into one mass instead of
    /// reading as a swarm of little ones.
    private func dilate(_ src: [UInt8], into dst: inout [UInt8]) {
        let gw = gridWidth, gh = gridHeight
        for i in 0..<(gw * gh) { dst[i] = 0 }
        for y in 0..<gh {
            let row = y * gw
            for x in 0..<gw where src[row + x] != 0 {
                for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= gh { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= gw { continue }
                        dst[yy * gw + xx] = 1
                    }
                }
            }
        }
    }

    /// 8-connected flood fill, with the second moments the beam test needs.
    private func components(_ mask: [UInt8], moments: Bool = false, cells wantCells: Bool = false) -> [Mass] {
        let gw = gridWidth, gh = gridHeight, n = gw * gh
        for i in 0..<n { lab[i] = 0 }
        var out: [Mass] = []
        var id: Int32 = 0
        for seed in 0..<n {
            if mask[seed] == 0 || lab[seed] != 0 { continue }
            id += 1
            var sp = 0
            stack[sp] = Int32(seed); sp += 1
            lab[seed] = id
            var area = 0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, lsum = 0.0
            var minx = gw, maxx = -1, miny = gh, maxy = -1, mcount = 0, scount = 0
            var cells: [Int] = []
            while sp > 0 {
                sp -= 1
                let p = Int(stack[sp])
                let px = p % gw, py = p / gw
                area += 1; sx += Double(px); sy += Double(py); lsum += Double(luma[p])
                if moments {
                    sxx += Double(px * px); syy += Double(py * py); sxy += Double(px * py)
                }
                if px < minx { minx = px }
                if px > maxx { maxx = px }
                if py < miny { miny = py }
                if py > maxy { maxy = py }
                if mot[p] != 0 { mcount += 1 }
                if skin[p] != 0 { scount += 1 }
                if wantCells { cells.append(p) }
                for dy in -1...1 {
                    let yy = py + dy
                    if yy < 0 || yy >= gh { continue }
                    for dx in -1...1 {
                        let xx = px + dx
                        if xx < 0 || xx >= gw { continue }
                        let q = yy * gw + xx
                        if mask[q] != 0 && lab[q] == 0 {
                            lab[q] = id
                            stack[sp] = Int32(q); sp += 1
                        }
                    }
                }
            }
            var m = Mass()
            m.area = area
            m.cx = sx / Double(area); m.cy = sy / Double(area)
            m.minx = minx; m.maxx = maxx; m.miny = miny; m.maxy = maxy
            m.w = maxx - minx + 1; m.h = maxy - miny + 1
            m.motion = mcount
            m.skinFrac = Double(scount) / Double(area)
            m.lumaMean = lsum / Double(area)
            if wantCells { m.cells = cells }
            if moments {
                // eigenvalues of the covariance matrix: how much of a streak this is
                let a = Double(area)
                let vx = sxx / a - m.cx * m.cx, vy = syy / a - m.cy * m.cy
                let vxy = sxy / a - m.cx * m.cy
                let tr = vx + vy, det = vx * vy - vxy * vxy
                let disc = max(0, tr * tr / 4 - det)
                let l1 = tr / 2 + disc.squareRoot(), l2 = tr / 2 - disc.squareRoot()
                m.elong = l2 > 0.5 ? (l1 / l2).squareRoot() : 6
            }
            out.append(m)
        }
        return out
    }

    // MARK: - One class of subject per frame

    private struct Scene {
        var mode: SubjectMode
        var subjects: [Mass]
        var beam: Mass?
    }

    private func overlap(_ a: Mass, _ b: Mass) -> Double {
        let ix = min(a.maxx, b.maxx) - max(a.minx, b.minx) + 1
        let iy = min(a.maxy, b.maxy) - max(a.miny, b.miny) + 1
        if ix <= 0 || iy <= 0 { return 0 }
        return Double(ix * iy) / Double(min(a.w * a.h, b.w * b.h))
    }

    private func classify() -> Scene {
        let gw = gridWidth, n = gw * gridHeight

        /* The two scales are measured on two masks, which matters more than it
           looks. One bee is a two-cell blob in the raw motion mask; grown by two
           cells to hold a body together it becomes seven, which is neither a mote
           nor a subject, and it would fall through the classifier entirely. */
        var smalls = components(mot).filter {
            $0.area >= 2 && $0.w <= CFG.moteMaxSide && $0.h <= CFG.moteMaxSide
        }

        dilate(mot, into: &dil)
        dilate(dil, into: &dilB)
        let movers = components(dilB).filter {
            $0.w >= CFG.subjMinSide && $0.h >= CFG.subjMinSide && $0.motion >= CFG.subjMinMotion
        }

        /* Not enough movers to call it a swarm? Look for grains by contrast, so a
           line of ants and a room of hanging dust both count. The two caps keep a
           brick wall or a gravel path from reading as a thousand insects. */
        if smalls.count < CFG.swarmMin {
            let spotArea = spotPass()
            if spotArea > 0 && Double(spotArea) < CFG.spotAreaFrac * Double(n) {
                let grains = components(spotM).filter {
                    $0.area >= 2 && $0.w <= CFG.moteMaxSide && $0.h <= CFG.moteMaxSide
                }
                if grains.count >= CFG.swarmMin && grains.count <= CFG.spotMaxCount {
                    smalls = grains
                }
            }
        }

        /* Skin is found on its own, not through motion. A face held still barely
           differences at all, and locking the hand because it was the only thing
           that moved is exactly the wrong answer. */
        dilate(skin, into: &dil)
        var flesh = components(dil).filter {
            $0.w >= CFG.subjMinSide && $0.h >= CFG.subjMinSide && $0.area >= CFG.skinMinArea
        }
        for i in flesh.indices { flesh[i].isFlesh = true }

        // a living frame is the flesh, plus anything else moving as one piece that
        // is not part of it: a bird, a cat, an arm in a sleeve
        var subjects = flesh
        for m in movers {
            if m.skinFrac >= CFG.subjSkinFrac { continue }
            if flesh.contains(where: { overlap($0, m) > 0.35 }) { continue }
            subjects.append(m)
        }

        // the light pass only runs when nothing living already owns the frame,
        // which is also the only reason a frame can afford it
        var beam: Mass? = nil
        let brightCount = subjects.isEmpty ? lightPass() : 0
        if Double(brightCount) > CFG.beamAreaFrac * Double(n) {
            dilate(brightM, into: &dil)
            var lumaTotal = 0.0
            for i in 0..<n { lumaTotal += Double(luma[i]) }
            var best: Mass? = nil
            for m in components(dil, moments: true, cells: true) {
                if Double(m.area) < CFG.beamAreaFrac * Double(n)
                    || Double(m.area) > CFG.beamAreaMax * Double(n) { continue }
                if m.elong < CFG.beamElong { continue }
                // A shaft of light is only a shaft because the room around it is
                // dark. Drop this test and a white wall, a lit window or a sheet of
                // paper all read as Tyndall, which is the one thing this mode is
                // not allowed to get wrong.
                let outside = (lumaTotal - m.lumaMean * Double(m.area)) / Double(max(1, n - m.area))
                if m.lumaMean - outside < CFG.beamContrast { continue }
                if best == nil || m.area > best!.area { best = m }
            }
            beam = best
        }

        // dust in a shaft is not a swarm of insects: if the little movers are
        // mostly inside the beam, they belong to it, and so does the frame
        var captured = 0
        if let b = beam, let cells = b.cells {
            for i in 0..<n { inBeam[i] = 0 }
            for p in cells { inBeam[p] = 1 }
            for m in smalls where inBeam[Int(m.cy) * gw + Int(m.cx)] != 0 { captured += 1 }
            // A motion mass inside the beam is the beam's own brightness moving
            // about, not a body. Flesh is exempt: it was found by colour, so a
            // hand held up in the shaft is still a hand.
            subjects.removeAll { s in
                if s.isFlesh { return false }
                var hit = 0, seen = 0
                var y = s.miny
                while y <= s.maxy {
                    var x = s.minx
                    while x <= s.maxx {
                        seen += 1
                        if inBeam[y * gw + x] != 0 { hit += 1 }
                        x += 2
                    }
                    y += 2
                }
                return seen > 0 && Double(hit) / Double(seen) > 0.6
            }
        }

        chaos = min(1, 0.6 * Double(motCount) / (0.05 * Double(n))
                    + 0.4 * min(1, Double(smalls.count) / 18))

        if !subjects.isEmpty { return Scene(mode: .living, subjects: subjects, beam: nil) }
        if beam != nil && (smalls.isEmpty || Double(captured) / Double(smalls.count) >= CFG.beamCapture) {
            return Scene(mode: .beam, subjects: [], beam: beam)
        }
        if smalls.count >= CFG.swarmMin { return Scene(mode: .swarm, subjects: smalls, beam: nil) }

        // nothing moved: fall back to the strongest static edge cluster, so the
        // lock is on the one solid thing in frame rather than on nothing
        for i in 0..<n { spotM[i] = 0 }
        var ecount = 0
        var i = 0
        while i < n - gw - 1 {
            if abs(Int(luma[i]) - Int(luma[i + 1])) + abs(Int(luma[i]) - Int(luma[i + gw])) > CFG.edge {
                spotM[i] = 1
                ecount += 1
            }
            i += 2
        }
        if ecount > 12 {
            dilate(spotM, into: &dil)
            dilate(dil, into: &dilB)
            var best: Mass? = nil
            for m in components(dilB) {
                if m.w < CFG.subjMinSide || m.h < CFG.subjMinSide { continue }
                if best == nil || m.area > best!.area { best = m }
            }
            if let b = best { return Scene(mode: .object, subjects: [b], beam: nil) }
        }
        return Scene(mode: .none, subjects: [], beam: nil)
    }

    /// Where a skin-coloured compact blob becomes a FACE and everything else that
    /// moves as one piece becomes a body or a creature.
    private func className(_ m: Mass, biggestSkin: Int) -> String {
        let aspect = Double(m.w) / Double(m.h)
        if m.skinFrac >= CFG.subjSkinFrac {
            if Double(m.area) < Double(biggestSkin) * CFG.handFrac { return "HAND" }
            if aspect > CFG.faceAspectLo && aspect < CFG.faceAspectHi { return "FACE" }
            return "BODY"
        }
        if aspect > 2.4 || aspect < 0.42 { return "LIMB" }
        return Double(m.area) > 0.06 * Double(gridWidth * gridHeight) ? "BODY" : "CREATURE"
    }

    // MARK: - Tracking

    private struct Target {
        let cls: String
        let x: Double, y: Double, w: Double, h: Double
        let conf: Double
    }

    private func target(_ m: Mass, _ cls: String) -> Target {
        Target(cls: cls,
               x: Double(m.minx + m.maxx + 1) / 2 * cell,
               y: Double(m.miny + m.maxy + 1) / 2 * cell,
               w: Double(m.w) * cell,
               h: Double(m.h) * cell,
               conf: min(1, 0.35 + Double(m.motion) / 120))
    }

    private func update(targets: [Target], maxMiss: Int) {
        for t in tracks { t.matched = false }
        for g in targets {
            var best: Track? = nil
            var bd = Double.infinity
            for t in tracks where !t.matched {
                let reach = 0.5 * (t.w + g.w) + 0.5 * (t.h + g.h) + 24
                let dx = t.x - g.x, dy = t.y - g.y
                let d = (dx * dx + dy * dy).squareRoot() / reach
                if d < bd { bd = d; best = t }
            }
            if let b = best, bd < 0.75 {
                // ease onto the measurement: a box that snaps looks like a bug, a
                // box that lags looks like it is tracking
                let k = 0.35
                b.x += (g.x - b.x) * k
                b.y += (g.y - b.y) * k
                b.w += (g.w - b.w) * k * 0.8
                b.h += (g.h - b.h) * k * 0.8
                b.cls = g.cls
                b.conf = g.conf
                b.matched = true
                b.miss = 0
                b.age += 1
            } else if tracks.count < CFG.maxTracks {
                let teal = rng.next() < 0.07
                let phase = rng.next() * 6.283
                let t = Track(id: nextId, cls: g.cls, x: g.x, y: g.y, w: g.w, h: g.h,
                              conf: g.conf, teal: teal, phase: phase)
                nextId += 1
                t.matched = true
                tracks.append(t)
            }
        }

        // Two locks on one subject reads as a fault, and easing onto the
        // measurement makes them easy to create: drop the younger of a pair.
        for i in 0..<tracks.count {
            for j in (i + 1)..<max(i + 1, tracks.count) {
                let a = tracks[i], b = tracks[j]
                let ix = min(a.x + a.w / 2, b.x + b.w / 2) - max(a.x - a.w / 2, b.x - b.w / 2)
                let iy = min(a.y + a.h / 2, b.y + b.h / 2) - max(a.y - a.h / 2, b.y - b.h / 2)
                if ix <= 0 || iy <= 0 { continue }
                if ix * iy / min(a.w * a.h, b.w * b.h) > 0.55 {
                    (a.age >= b.age ? b : a).miss = maxMiss + 1
                }
            }
        }
        for t in tracks where !t.matched {
            t.miss += 1
            t.age += 1
        }
        for t in tracks where t.miss > maxMiss { t.dead = true }
        tracks.removeAll { $0.dead }
        links.removeAll { $0.a.dead || $0.b.dead }

        // wire the locks to each other: face to hand, mote to nearest mote
        if (mode == .living || mode == .swarm) && tracks.count > 1 && links.count < CFG.maxLinks
            && rng.next() < (mode == .swarm ? 0.55 : 0.3) {
            let a = tracks[Int(rng.next() * Double(tracks.count))]
            var b: Track? = nil
            var bd = Double.infinity
            for t in tracks where t !== a {
                let dx = t.x - a.x, dy = t.y - a.y
                let d = (dx * dx + dy * dy).squareRoot()
                if d < bd { bd = d; b = t }
            }
            if let b { links.append(Link(a: a, b: b)) }
        }
    }

    // MARK: - The flood

    private func spawnMote(owner: Track?, x: Double, y: Double) {
        let r = rng.next()
        let vx = (rng.next() - 0.5) * 0.25
        let vy = (rng.next() - 0.5) * 0.25
        let ttl = 30 + rng.next() * 120
        let size = 8 + rng.next() * 4
        let kind: Mote.Kind = r < 0.82 ? .tag : r < 0.97 ? .box : .fill
        let w = 12 + rng.next() * 40
        let h = 7 + rng.next() * 26
        let teal = rng.next() < 0.05
        let m = Mote(id: nextId, owner: owner, x: x, y: y, vx: vx, vy: vy,
                     ttl: ttl, size: size, kind: kind, w: w, h: h, teal: teal)
        nextId += 1
        if let o = owner {
            m.ox = (x - o.x) / max(1, o.w)
            m.oy = (y - o.y) / max(1, o.h)
        }
        motes.append(m)
    }

    private func updateMotes(beam: Mass?) {
        let gw = gridWidth, n = gw * gridHeight
        // How much numeric noise the frame has earned. A shaft of light gets
        // flooded; a lock gets its own allowance, so two hands in frame are twice
        // as busy as one.
        let budget: Int
        switch mode {
        case .none, .swarm: budget = 0
        case .beam: budget = Int((150 + chaos * 290).rounded())
        default: budget = Int((Double(tracks.count) * (16 + chaos * 54)).rounded())
        }

        for m in motes {
            m.age += 1
            if let o = m.owner {
                // follow the owner, then drift inside it
                m.x = o.x + m.ox * o.w + m.vx * m.age * 0.35
                m.y = o.y + m.oy * o.h + m.vy * m.age * 0.35
                m.dead = m.age >= m.ttl || o.dead
                    || abs(m.x - o.x) > o.w * 0.5 || abs(m.y - o.y) > o.h * 0.5
            } else {
                m.x += m.vx + (rng.next() - 0.5) * 0.5
                m.y += m.vy + (rng.next() - 0.5) * 0.5
                let gx = Int(m.x / cell), gy = Int(m.y / cell)
                let gi = gy * gw + gx
                m.dead = m.age >= m.ttl || beam == nil || gx < 0 || gx >= gw
                    || gi < 0 || gi >= n || inBeam[gi] == 0
            }
        }
        motes.removeAll { $0.dead }

        var want = min(CFG.maxMotes, budget) - motes.count
        var guardCount = want * 4
        while want > 0 && guardCount > 0 {
            guardCount -= 1
            if mode == .beam {
                // the mode is held for a few frames after a beam is lost, so this
                // can be the beam mode with no beam in hand
                guard let cells = beam?.cells, !cells.isEmpty else { break }
                let p = cells[Int(rng.next() * Double(cells.count))]
                spawnMote(owner: nil,
                          x: (Double(p % gw) + rng.next()) * cell,
                          y: (Double(p / gw) + rng.next()) * cell)
                want -= 1
            } else if !tracks.isEmpty {
                // swarm members are too small to hold a flood; one label each
                if mode == .swarm { break }
                let t = tracks[Int(rng.next() * Double(tracks.count))]
                spawnMote(owner: t,
                          x: t.x + (rng.next() - 0.5) * t.w * 0.8,
                          y: t.y + (rng.next() - 0.5) * t.h * 0.8)
                want -= 1
            } else { break }
        }
        if motes.count > CFG.maxMotes { motes.removeFirst(motes.count - CFG.maxMotes) }
    }

    // MARK: - For the scene

    /// White ink over a bright frame is invisible, and half of what this gets
    /// pointed at is bright. So the ink is chosen from the luminance under it.
    func isBright(at x: Double, _ y: Double) -> Bool {
        guard !luma.isEmpty else { return false }
        let gx = min(gridWidth - 1, max(0, Int(x / cell)))
        let gy = min(gridHeight - 1, max(0, Int(y / cell)))
        return luma[gy * gridWidth + gx] > 150
    }

    /// True where a beam cell has a non-beam neighbour: the silhouette.
    func beamEdge(_ p: Int) -> Bool {
        let gw = gridWidth, n = gw * gridHeight
        let x = p % gw, y = p / gw
        if x == 0 || x == gw - 1 || y == 0 || y == gridHeight - 1 { return true }
        guard p - gw >= 0, p + gw < n else { return true }
        return inBeam[p - 1] == 0 || inBeam[p + 1] == 0 || inBeam[p - gw] == 0 || inBeam[p + gw] == 0
    }

    func trackFade(_ t: Track) -> Double {
        min(1, Double(t.age + 1) / 5) * (t.miss > 0 ? 0.45 : 1) * (0.55 + 0.45 * t.conf)
    }
}
