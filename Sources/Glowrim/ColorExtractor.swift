import AppKit

/// Pulls two vivid, distinct colors out of an album cover.
enum ColorExtractor {
    static func palette(from image: NSImage) -> (NSColor, NSColor)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let w = 24, h = 24
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // 12 hue buckets, weighted by how colorful each pixel is.
        let bins = 12
        var weight = [CGFloat](repeating: 0, count: bins)
        var rs = [CGFloat](repeating: 0, count: bins)
        var gs = rs, bs = rs
        var avgR: CGFloat = 0, avgG: CGFloat = 0, avgB: CGFloat = 0

        for i in stride(from: 0, to: px.count, by: 4) {
            let r = CGFloat(px[i]) / 255, g = CGFloat(px[i + 1]) / 255, b = CGFloat(px[i + 2]) / 255
            avgR += r; avgG += g; avgB += b
            let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
            c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
            guard bri > 0.15, sat > 0.15 else { continue }
            let wgt = sat * sat * bri
            let k = min(bins - 1, Int(hue * CGFloat(bins)))
            weight[k] += wgt
            rs[k] += r * wgt; gs[k] += g * wgt; bs[k] += b * wgt
        }

        let n = CGFloat(w * h)
        let order = (0..<bins).sorted { weight[$0] > weight[$1] }
        let top = order[0]

        func color(_ k: Int) -> NSColor {
            NSColor(srgbRed: rs[k] / weight[k], green: gs[k] / weight[k], blue: bs[k] / weight[k], alpha: 1)
        }

        // Mostly black-and-white cover: use a soft tinted white.
        guard weight[top] > 2 else {
            let base = NSColor(srgbRed: avgR / n, green: avgG / n, blue: avgB / n, alpha: 1)
            let primary = base.lerp(to: .white, 0.7)
            return (primary, primary.lerp(to: NSColor(srgbRed: 0.7, green: 0.8, blue: 1, alpha: 1), 0.5))
        }

        let primary = color(top)
        let secondary: NSColor
        if let k = order.dropFirst().first(where: { k in
            let dist = min(abs(k - top), bins - abs(k - top))
            return dist >= 2 && weight[k] > weight[top] * 0.15
        }) {
            secondary = color(k)
        } else {
            secondary = shiftHue(primary, by: 0.08)
        }
        return (vivid(primary), vivid(secondary))
    }

    private static func vivid(_ c: NSColor) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: max(s, 0.6), brightness: max(b, 0.9), alpha: 1)
    }

    private static func shiftHue(_ c: NSColor, by d: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: (h + d).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1)
    }
}
