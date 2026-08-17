import SpriteKit

/// Draws the tracking layer over the camera picture: link lines, then labels.
///
/// The scene is transparent — the camera preview sits behind it — and every
/// element is a sprite taken from one of two textures, the white pixel or the
/// digit strip, so SpriteKit batches the whole overlay into a handful of draw
/// calls even with 450 labels on screen.
///
/// The simulation keeps the web build's y-down coordinates. This class flips the
/// sign once, in `flip`.
final class TrackerScene: SKScene {

    let sim = TrackerSim()

    /// Called whenever the view size changes, with the new motion-grid height.
    var onResize: ((Int) -> Void)?

    private static let white = SKColor(red: 1, green: 1, blue: 1, alpha: 1)
    private static let teal = SKColor(red: 127 / 255, green: 216 / 255, blue: 216 / 255, alpha: 1)
    private static let lineWidth: CGFloat = 0.75

    private let lineLayer = SKNode()
    private let rectLayer = SKNode()
    private let digitLayer = SKNode()

    private var linePool: [SKSpriteNode] = []
    private var rectPool: [SKSpriteNode] = []
    private var digitPool: [SKSpriteNode] = []
    private var lineUsed = 0
    private var rectUsed = 0
    private var digitUsed = 0

    private lazy var whiteTex = DigitAtlas.whiteTexture()
    private lazy var atlas = DigitAtlas.build()

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = CGPoint(x: 0, y: 0)
        backgroundColor = .clear
        lineLayer.zPosition = 0
        rectLayer.zPosition = 1
        digitLayer.zPosition = 2
        addChild(lineLayer)
        addChild(rectLayer)
        addChild(digitLayer)
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
        onResize?(sim.gridHeight)
    }

    // MARK: - One camera frame

    /// Steps the simulation on the grid taken from the frame, then lays the
    /// overlay out again. Called on the main thread, once per camera frame, so
    /// the labels move at the frame rate of the camera rather than the display.
    func ingest(grid: [UInt8]) {
        guard grid.count == TrackerSim.gridWidth * sim.gridHeight else { return }
        sim.step(lum: grid)
        layoutOverlay()
    }

    /// Forgets the previous frame, so the cut between the two cameras does not
    /// read as one enormous burst of movement. The labels already on screen stay
    /// and decay, exactly as they do in the web build.
    func cameraSwitched() {
        sim.resize(width: sim.width, height: sim.height)
    }

    private func flip(_ y: Double) -> CGFloat { CGFloat(sim.height - y) }

    private func layoutOverlay() {
        lineUsed = 0
        rectUsed = 0
        digitUsed = 0

        // lines under labels, same as the web build
        for l in sim.links {
            let ax = CGFloat(l.a.x), ay = flip(l.a.y)
            let dx = CGFloat(l.b.x) - ax, dy = flip(l.b.y) - ay
            let len = (dx * dx + dy * dy).squareRoot()
            let n = takeLine()
            n.size = CGSize(width: max(len, 0.5), height: Self.lineWidth)
            n.position = CGPoint(x: ax, y: ay)
            n.zRotation = atan2(dy, dx)
            n.color = Self.white
            n.alpha = 0.5
        }

        for t in sim.trackers {
            let fade = t.fade
            guard fade > 0.01 else { continue }
            let colour = t.teal ? Self.teal : Self.white
            let x = CGFloat(t.x)

            switch t.kind {
            case .fill:
                // filled chip with the id knocked out in black
                let chipH = CGFloat(t.h * 0.35)
                rect(x: x, y: flip(t.y), w: CGFloat(t.w * 0.8), h: chipH,
                     colour: colour, alpha: 0.85 * fade)
                number(t.id, x: x + 3, baseline: flip(t.y) + 2, size: CGFloat(t.size),
                       colour: .black, alpha: 0.8 * fade)
            case .box, .tag:
                if t.kind == .box {
                    outline(x: x - CGFloat(t.w) / 2, y: flip(t.y) - CGFloat(t.h) - 2,
                            w: CGFloat(t.w), h: CGFloat(t.h),
                            colour: colour, alpha: 0.75 * fade)
                }
                tick(x: x, y: flip(t.y), colour: colour, alpha: 0.9 * fade)
                number(t.id, x: x + 3, baseline: flip(t.y), size: CGFloat(t.size),
                       colour: colour, alpha: 0.92 * fade)
            }
        }

        for i in lineUsed..<linePool.count { linePool[i].isHidden = true }
        for i in rectUsed..<rectPool.count { rectPool[i].isHidden = true }
        for i in digitUsed..<digitPool.count { digitPool[i].isHidden = true }
    }

    // MARK: - Pieces

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
        rect(x: x, y: y, w: w, h: t, colour: colour, alpha: alpha)                 // bottom
        rect(x: x, y: y + h - t, w: w, h: t, colour: colour, alpha: alpha)         // top
        rect(x: x, y: y, w: t, h: h, colour: colour, alpha: alpha)                 // left
        rect(x: x + w - t, y: y, w: t, h: h, colour: colour, alpha: alpha)         // right
    }

    /// The little corner tick that sits before the number.
    private func tick(x: CGFloat, y: CGFloat, colour: SKColor, alpha: Double) {
        let t = Self.lineWidth
        rect(x: x - 2 - t / 2, y: y - 3, w: t, h: 3 + t, colour: colour, alpha: alpha)
        rect(x: x - 2 - t / 2, y: y - t / 2, w: 4 + t, h: t, colour: colour, alpha: alpha)
    }

    /// Draws `value` with its baseline on `baseline`, left edge at `x`.
    private func number(_ value: Int, x: CGFloat, baseline: CGFloat, size: CGFloat,
                        colour: SKColor, alpha: Double) {
        let scale = size / atlas.fontSize
        var digits: [Int] = []
        var v = max(0, value)
        repeat {
            digits.append(v % 10)
            v /= 10
        } while v > 0
        var pen = x
        let bottom = baseline - atlas.descent * scale
        for d in digits.reversed() {
            let n = takeDigit()
            n.texture = atlas.digits[d]
            n.size = CGSize(width: atlas.cellWidths[d] * scale, height: atlas.cellHeight * scale)
            n.position = CGPoint(x: pen, y: bottom)
            n.color = colour
            n.alpha = CGFloat(alpha)
            pen += atlas.advances[d] * scale
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

    private func takeDigit() -> SKSpriteNode {
        if digitUsed == digitPool.count {
            digitPool.append(newSprite(texture: atlas.digits[0], anchor: .zero, parent: digitLayer))
        }
        let n = digitPool[digitUsed]
        digitUsed += 1
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
