import SpriteKit

/// Draws the tracking layer over the camera picture: the locks on whatever class
/// of subject the frame turned out to be about, the numeric flood inside them,
/// and the readout.
///
/// The scene is transparent — the camera preview sits behind it — and every
/// element is a sprite taken from one of two textures, the white pixel or the
/// glyph strip, so SpriteKit batches the whole overlay into a handful of draw
/// calls however busy the frame gets.
///
/// The simulation keeps the web build's y-down coordinates. This class flips the
/// sign once, in `flip`.
final class TrackerScene: SKScene {

    let sim = TrackerSim()

    /// Called whenever the view size changes, with the new motion-grid shape.
    var onResize: ((Int, Int) -> Void)?

    private static let white = SKColor(red: 1, green: 1, blue: 1, alpha: 1)
    private static let teal = SKColor(red: 127 / 255, green: 216 / 255, blue: 216 / 255, alpha: 1)
    private static let dark = SKColor(red: 18 / 255, green: 20 / 255, blue: 26 / 255, alpha: 1)
    private static let lineWidth: CGFloat = 0.75

    private let lineLayer = SKNode()
    private let rectLayer = SKNode()
    private let glyphLayer = SKNode()

    private var linePool: [SKSpriteNode] = []
    private var rectPool: [SKSpriteNode] = []
    private var glyphPool: [SKSpriteNode] = []
    private var lineUsed = 0
    private var rectUsed = 0
    private var glyphUsed = 0

    private lazy var whiteTex = DigitAtlas.whiteTexture()
    private lazy var atlas = DigitAtlas.build()

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = CGPoint(x: 0, y: 0)
        backgroundColor = .clear
        lineLayer.zPosition = 0
        rectLayer.zPosition = 1
        glyphLayer.zPosition = 2
        addChild(lineLayer)
        addChild(rectLayer)
        addChild(glyphLayer)
        sim.resize(width: Double(size.width), height: Double(size.height))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        view.ignoresSiblingOrder = true
        view.allowsTransparency = true
        applySize(size)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        applySize(size)
    }

    private func applySize(_ s: CGSize) {
        guard s.width > 1, s.height > 1 else { return }
        sim.resize(width: Double(s.width), height: Double(s.height))
        onResize?(sim.gridWidth, sim.gridHeight)
    }

    // MARK: - One camera frame

    /// Steps the detector on the frame, then lays the overlay out again. Called on
    /// the main thread, once per camera frame, so the overlay moves at the frame
    /// rate of the camera rather than the display.
    func ingest(frame: FrameGrid) {
        guard frame.width == sim.gridWidth, frame.height == sim.gridHeight else { return }
        sim.step(luma: frame.luma, skin: frame.skin)
        layoutOverlay()
    }

    /// The cut between the two cameras is not movement.
    func cameraSwitched() { sim.forgetPreviousFrame() }

    private func flip(_ y: Double) -> CGFloat { CGFloat(sim.height - y) }

    private func colour(at x: Double, _ y: Double, teal: Bool) -> SKColor {
        if teal { return Self.teal }
        return sim.isBright(at: x, y) ? Self.dark : Self.white
    }

    private func layoutOverlay() {
        lineUsed = 0
        rectUsed = 0
        glyphUsed = 0

        if sim.mode == .beam { drawBeamEdge() }

        // link lines, under everything
        for l in sim.links {
            line(from: CGPoint(x: CGFloat(l.a.x), y: flip(l.a.y)),
                 to: CGPoint(x: CGFloat(l.b.x), y: flip(l.b.y)),
                 colour: Self.white, alpha: 0.45)
        }

        for t in sim.tracks {
            let fade = sim.trackFade(t)
            guard fade > 0.02 else { continue }
            let c = colour(at: t.x, t.y, teal: t.teal)
            let x = CGFloat(t.x), y = flip(t.y)
            let w = CGFloat(t.w), h = CGFloat(t.h)

            if sim.mode == .swarm {
                // one bee, one box, one number
                outline(x: x - max(6, w) / 2, y: y - max(6, h) / 2,
                        w: max(6, w), h: max(6, h), colour: c, alpha: 0.7 * fade)
                text(String(t.id), x: x + max(6, w) / 2 + 2, baseline: y + max(6, h) / 2,
                     size: 8.5, colour: c, alpha: 0.85 * fade, tick: false)
                continue
            }

            brackets(x: x, y: y, w: w, h: h, colour: c, alpha: 0.9 * fade)
            text("\(t.cls) \(t.id)", x: x - w / 2, baseline: y + h / 2 + 5,
                 size: 11, colour: c, alpha: 0.95 * fade, tick: true)
            // a scan line crossing the lock, so it reads as being examined
            let sweep = (Double(sim.frameCount) * 2.4 + t.phase * 40).truncatingRemainder(dividingBy: t.h)
            let sy = y + h / 2 - CGFloat(sweep)
            line(from: CGPoint(x: x - w / 2, y: sy), to: CGPoint(x: x + w / 2, y: sy),
                 colour: c, alpha: 0.3 * fade)
            text("\(Int(t.conf * 100))%", x: x - w / 2, baseline: y - h / 2 - 11,
                 size: 8.5, colour: c, alpha: 0.5 * fade, tick: false)
        }

        for m in sim.motes {
            let fade = m.fade
            guard fade > 0.02 else { continue }
            let c = colour(at: m.x, m.y, teal: m.teal)
            let x = CGFloat(m.x), y = flip(m.y)

            switch m.kind {
            case .fill:
                var chip = CGFloat(m.w) * 0.8
                if let o = m.owner { chip = min(chip, CGFloat(o.x + o.w / 2 - m.x)) }
                chip = max(chip, 6)
                rect(x: x, y: y, w: chip, h: CGFloat(m.h) * 0.35, colour: c, alpha: 0.8 * fade)
                text(String(m.id), x: x + 3, baseline: y + 2, size: CGFloat(m.size),
                     colour: c == Self.white ? .black : SKColor(white: 0.96, alpha: 1),
                     alpha: 0.8 * fade, tick: false)
            case .box:
                // a mark's box never pokes out of the lock it belongs to
                var bw = CGFloat(m.w), bh = CGFloat(m.h)
                if let o = m.owner {
                    bw = min(bw, CGFloat((o.w * 0.5 - abs(m.x - o.x)) * 2))
                    bh = min(bh, CGFloat(m.y - (o.y - o.h / 2)) - 2)
                }
                if bw > 3 && bh > 3 {
                    outline(x: x - bw / 2, y: y - bh - 2, w: bw, h: bh, colour: c, alpha: 0.6 * fade)
                }
                text(String(m.id), x: x, baseline: y, size: CGFloat(m.size),
                     colour: c, alpha: 0.9 * fade, tick: true)
            case .tag:
                text(String(m.id), x: x, baseline: y, size: CGFloat(m.size),
                     colour: c, alpha: 0.9 * fade, tick: true)
            }
        }

        readout()

        for i in lineUsed..<linePool.count { linePool[i].isHidden = true }
        for i in rectUsed..<rectPool.count { rectPool[i].isHidden = true }
        for i in glyphUsed..<glyphPool.count { glyphPool[i].isHidden = true }
    }

    /// Which class the frame got locked to, and how busy it is.
    private func readout() {
        let lines = [
            "TRACKING \(sim.mode.readout)",
            "LOCKS \(sim.tracks.count)  MARKS \(sim.motes.count)",
            String(format: "CHAOS %.2f  GRID %dx%d", sim.chaos, sim.gridWidth, sim.gridHeight),
        ]
        for (i, l) in lines.enumerated() {
            text(l, x: 12, baseline: CGFloat(12 + (lines.count - 1 - i) * 12),
                 size: 9, colour: Self.white, alpha: 0.4, tick: false)
        }
    }

    /// The beam's silhouette, ticked along its boundary cells.
    private func drawBeamEdge() {
        let cell = CGFloat(sim.cell)
        var k = 0
        while k < sim.beamCells.count {
            let p = sim.beamCells[k]
            k += 2
            guard sim.beamEdge(p) else { continue }
            let x = CGFloat(p % sim.gridWidth) * cell
            let y = flip(Double(p / sim.gridWidth) * sim.cell)
            rect(x: x, y: y, w: cell * 0.7, h: Self.lineWidth, colour: Self.dark, alpha: 0.5)
        }
    }

    // MARK: - Pieces

    private func line(from a: CGPoint, to b: CGPoint, colour: SKColor, alpha: Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        let n = takeLine()
        n.size = CGSize(width: max(len, 0.5), height: Self.lineWidth)
        n.position = a
        n.zRotation = atan2(dy, dx)
        n.color = colour
        n.alpha = CGFloat(alpha)
    }

    /// Bottom-left anchored solid rectangle.
    private func rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                      colour: SKColor, alpha: Double) {
        let n = takeRect()
        n.size = CGSize(width: max(w, 0.5), height: max(h, 0.5))
        n.position = CGPoint(x: x, y: y)
        n.color = colour
        n.alpha = CGFloat(alpha)
    }

    private func outline(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                         colour: SKColor, alpha: Double) {
        let t = Self.lineWidth
        rect(x: x, y: y, w: w, h: t, colour: colour, alpha: alpha)
        rect(x: x, y: y + h - t, w: w, h: t, colour: colour, alpha: alpha)
        rect(x: x, y: y, w: t, h: h, colour: colour, alpha: alpha)
        rect(x: x + w - t, y: y, w: t, h: h, colour: colour, alpha: alpha)
    }

    /// Corner brackets and a faint full box: a viewfinder rather than a rectangle,
    /// which is what makes a lock look like a lock.
    private func brackets(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                          colour: SKColor, alpha: Double) {
        let x0 = x - w / 2, x1 = x + w / 2
        let y0 = y - h / 2, y1 = y + h / 2
        let arm = min(22, min(w, h) * 0.28)
        let t: CGFloat = 1.6
        for (cx, cy, sx, sy) in [(x0, y0, 1.0, 1.0), (x1, y0, -1.0, 1.0),
                                 (x0, y1, 1.0, -1.0), (x1, y1, -1.0, -1.0)] {
            let hx = sx > 0 ? cx : cx - arm
            rect(x: hx, y: sy > 0 ? cy : cy - t, w: arm, h: t, colour: colour, alpha: alpha)
            let vy = sy > 0 ? cy : cy - arm
            rect(x: sx > 0 ? cx : cx - t, y: vy, w: t, h: arm, colour: colour, alpha: alpha)
        }
        let thin = Self.lineWidth
        rect(x: x0, y: y0, w: w, h: thin, colour: colour, alpha: alpha * 0.22)
        rect(x: x0, y: y1 - thin, w: w, h: thin, colour: colour, alpha: alpha * 0.22)
        rect(x: x0, y: y0, w: thin, h: h, colour: colour, alpha: alpha * 0.22)
        rect(x: x1 - thin, y: y0, w: thin, h: h, colour: colour, alpha: alpha * 0.22)
    }

    /// Draws `s` with its baseline on `baseline`, left edge at `x`, optionally
    /// behind the little corner tick the web build puts before a number.
    private func text(_ s: String, x: CGFloat, baseline: CGFloat, size: CGFloat,
                      colour: SKColor, alpha: Double, tick: Bool) {
        if tick {
            let t = Self.lineWidth
            rect(x: x - 2 - t / 2, y: baseline - 3, w: t, h: 3 + t, colour: colour, alpha: alpha)
            rect(x: x - 2 - t / 2, y: baseline - t / 2, w: 4 + t, h: t, colour: colour, alpha: alpha)
        }
        let scale = size / atlas.fontSize
        var pen = x + (tick ? 3 : 0)
        let bottom = baseline - atlas.descent * scale
        for ch in s {
            guard let slot = atlas.slot(ch) else { continue }
            if ch != " " {
                let n = takeGlyph()
                n.texture = atlas.digits[slot]
                n.size = CGSize(width: atlas.cellWidths[slot] * scale,
                                height: atlas.cellHeight * scale)
                n.position = CGPoint(x: pen, y: bottom)
                n.color = colour
                n.alpha = CGFloat(alpha)
            }
            pen += atlas.advances[slot] * scale
        }
    }

    // MARK: - Pools
    //
    // Grown on demand and never shrunk. Nothing is created or destroyed once a
    // busy scene has been through a few frames.

    private func takeLine() -> SKSpriteNode {
        if lineUsed == linePool.count {
            linePool.append(newSprite(texture: whiteTex, anchor: CGPoint(x: 0, y: 0.5), parent: lineLayer))
        }
        let n = linePool[lineUsed]
        lineUsed += 1
        n.isHidden = false
        return n
    }

    private func takeRect() -> SKSpriteNode {
        if rectUsed == rectPool.count {
            rectPool.append(newSprite(texture: whiteTex, anchor: .zero, parent: rectLayer))
        }
        let n = rectPool[rectUsed]
        rectUsed += 1
        n.isHidden = false
        n.zRotation = 0
        return n
    }

    private func takeGlyph() -> SKSpriteNode {
        if glyphUsed == glyphPool.count {
            glyphPool.append(newSprite(texture: atlas.digits[0], anchor: .zero, parent: glyphLayer))
        }
        let n = glyphPool[glyphUsed]
        glyphUsed += 1
        n.isHidden = false
        return n
    }

    private func newSprite(texture: SKTexture, anchor: CGPoint, parent: SKNode) -> SKSpriteNode {
        let n = SKSpriteNode(texture: texture)
        n.anchorPoint = anchor
        n.colorBlendFactor = 1
        n.color = Self.white
        n.isHidden = true
        parent.addChild(n)
        return n
    }
}
