import CoreGraphics
import CoreText
import SpriteKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One strip holding every character the overlay can draw.
///
/// Labels are drawn as glyph sprites cut out of this one texture, which is the
/// only reason the overlay is cheap: sprites that share a texture get batched,
/// so hundreds of labels cost a couple of draw calls. Giving every label its own
/// text texture would mean one draw call each, plus a rasterisation per lock.
struct DigitAtlas {

    /// Digits for the ids, capitals for the class names and the readout.
    static let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ .%x-:")

    /// Rendered at this point size; a sprite scales by `size / fontSize`.
    let fontSize: CGFloat
    /// Cell height, and how far the baseline sits above the cell bottom.
    let cellHeight: CGFloat
    let descent: CGFloat
    /// Per character, in the order of `characters`: the cut-out texture, the pen
    /// advance, and the width of the cell that texture covers, in atlas points.
    let digits: [SKTexture]
    let advances: [CGFloat]
    let cellWidths: [CGFloat]
    /// Character to index in the arrays above.
    let index: [Character: Int]

    func slot(_ c: Character) -> Int? { index[c] }

    static func condensedFont(size: CGFloat) -> CTFont {
        #if os(iOS)
        return UIFont.systemFont(ofSize: size, weight: .regular, width: .condensed) as CTFont
        #else
        return NSFont.systemFont(ofSize: size, weight: .regular, width: .condensed) as CTFont
        #endif
    }

    /// 36pt is a shade above the biggest label at 3x, so nothing is ever
    /// magnified; mipmaps take care of the shrinking.
    static func build(fontSize: CGFloat = 36) -> DigitAtlas {
        let font = condensedFont(size: fontSize)

        let set = characters
        let count = set.count
        var chars = Array(String(set).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, count)
        var sizes = [CGSize](repeating: .zero, count: count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &sizes, count)
        var index: [Character: Int] = [:]
        for (i, c) in set.enumerated() { index[c] = i }

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let cellH = ceil(ascent + descent)
        let advances = sizes.map { $0.width }
        let cellW = advances.map { max(1, ceil($0)) }
        // gap between cells, so no mip level bleeds a neighbour in
        let pad: CGFloat = 4

        let stripW = Int(cellW.reduce(0, +) + pad * CGFloat(count))
        let stripH = Int(cellH)
        let scale: CGFloat = 2
        let pxW = stripW * Int(scale), pxH = stripH * Int(scale)

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return DigitAtlas(fontSize: fontSize, cellHeight: cellH, descent: descent,
                              digits: Array(repeating: SKTexture(), count: count),
                              advances: advances, cellWidths: cellW, index: index)
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setAllowsAntialiasing(true)

        var pen: CGFloat = 0
        var rects: [CGRect] = []
        for d in 0..<count {
            var glyph = glyphs[d]
            var at = CGPoint(x: pen, y: descent)
            CTFontDrawGlyphs(font, &glyph, &at, 1, ctx)
            rects.append(CGRect(x: pen, y: 0, width: cellW[d], height: cellH))
            pen += cellW[d] + pad
        }

        guard let image = ctx.makeImage() else {
            return DigitAtlas(fontSize: fontSize, cellHeight: cellH, descent: descent,
                              digits: Array(repeating: SKTexture(), count: count),
                              advances: advances, cellWidths: cellW, index: index)
        }
        let sheet = SKTexture(cgImage: image)
        sheet.usesMipmaps = true
        // The strip is one row, so only the horizontal span matters and
        // SpriteKit's bottom-left texture origin never comes into it.
        let digits = rects.map { r in
            SKTexture(rect: CGRect(x: r.minX / CGFloat(stripW), y: 0,
                                   width: r.width / CGFloat(stripW), height: 1),
                      in: sheet)
        }
        return DigitAtlas(fontSize: fontSize, cellHeight: cellH, descent: descent,
                          digits: digits, advances: advances, cellWidths: cellW, index: index)
    }

    /// A 1x1 white pixel: every line, box edge and label chip is this one
    /// texture, stretched and tinted.
    static func whiteTexture() -> SKTexture {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return SKTexture()
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: image)
    }
}
