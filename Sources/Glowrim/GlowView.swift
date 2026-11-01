import AppKit
import QuartzCore
import CoreImage

/// Click-through, transparent window that covers one display, above everything.
final class OverlayWindow: NSPanel {
    let glowView: GlowView
    let displayID: CGDirectDisplayID

    init(screen: NSScreen) {
        displayID = screen.displayID
        glowView = GlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        glowView.autoresizingMask = [.width, .height]
        contentView = glowView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the rim light: a sharp gradient band along the screen edge plus a blurred bloom.
final class GlowView: NSView {
    private let bloomContainer = CALayer()
    private let bloomGradient = CAGradientLayer()
    private let bloomMask = CAShapeLayer()

    private let coreContainer = CALayer()
    private let coreGradient = CAGradientLayer()
    private let coreMask = CAShapeLayer()

    var notch: CGRect? { didSet { needsLayout = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }

    /// What's drawn right now; eases toward the targets so slider drags never jump.
    private var thickness: CGFloat = 8
    private var glow: CGFloat = 0.6
    private var targetThickness: CGFloat = 8
    private var targetGlow: CGFloat = 0.6
    private var configured = false
    private var waveGain: CGFloat = 0
    private var borderOnly = false
    private var cornerMasks = [CALayer(), CALayer()] // core, bloom: dim the rim near the corners
    private var cometActive = false
    private var edge = EdgeContour(path: CGMutablePath(), source: .zero)
    private var basePath: CGPath?
    private var bloomBasePath: CGPath?
    /// The bloom is soft anyway, so it is drawn and blurred at a fraction of the screen size and
    /// scaled up by the compositor: far less GPU work than blurring a full-resolution layer.
    private var bloomScale: CGFloat { borderOnly ? 2 : 4 }
    private var waveActive = false
    /// Recent beat levels, newest last; a beat's ripple travels outward from the bottom centre.
    private var history = [CGFloat](repeating: 0.1, count: 240)
    private var frameCount = 0
    private var movieLocations: [NSNumber] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        guard let root = layer else { return }
        root.backgroundColor = CGColor.clear

        for g in [bloomGradient, coreGradient] {
            g.type = .conic
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 0.5, y: 1)
        }
        for m in [bloomMask, coreMask] {
            m.fillColor = nil
            m.strokeColor = NSColor.white.cgColor
            m.lineJoin = .round
        }

        bloomGradient.mask = bloomMask
        bloomContainer.addSublayer(bloomGradient)

        coreGradient.mask = coreMask
        coreContainer.addSublayer(coreGradient)
        coreContainer.shadowOffset = .zero

        root.addSublayer(bloomContainer)
        root.addSublayer(coreContainer)
        configure(thickness: thickness, glow: glow, borderOnly: borderOnly)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [layer, bloomContainer, bloomGradient, bloomMask, coreContainer, coreGradient, coreMask] {
            l?.contentsScale = scale
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let k = bloomScale
        for l in [coreContainer, coreGradient, coreMask] {
            l.frame = b
        }
        let small = CGRect(x: 0, y: 0, width: b.width / k, height: b.height / k)
        bloomContainer.bounds = small
        bloomContainer.position = CGPoint(x: b.midX, y: b.midY)
        bloomContainer.transform = CATransform3DMakeScale(k, k, 1)
        for l in [bloomGradient, bloomMask] {
            l.frame = small
        }
        let maskImage = Self.cornerFade(size: b.size)
        cornerMasks[0].frame = b
        cornerMasks[1].frame = small
        for m in cornerMasks { m.contents = maskImage }
        let path = Self.edgePath(in: b, radius: cornerRadius, notch: notch)
        var down = CGAffineTransform(scaleX: 1 / k, y: 1 / k)
        basePath = path
        bloomBasePath = path.copy(using: &down)
        bloomMask.path = bloomBasePath
        coreMask.path = path
        edge = EdgeContour(path: path, source: CGPoint(x: b.midX, y: b.minY))
        waveActive = false
        CATransaction.commit()
    }

    /// Called when thickness / glow settings change.
    func configure(thickness: CGFloat, glow: CGFloat, borderOnly: Bool) {
        targetThickness = thickness
        targetGlow = glow
        if !configured || borderOnly != self.borderOnly {
            configured = true
            self.thickness = thickness
            self.glow = glow
        }
        if borderOnly != self.borderOnly { needsLayout = true }
        self.borderOnly = borderOnly
        applyGeometry()
    }

    private func applyGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // The path sits on the screen edge, so only the inner half of each stroke is visible.
        // Border-only keeps a tight blurred halo hugging the band; otherwise the bloom spills far.
        let reach = borderOnly ? thickness * 1.8 + 4 + 14 * glow : thickness + 20 + 160 * glow
        let blurRadius = borderOnly ? 4 + thickness * 0.6 + 10 * glow : 20 + 70 * glow
        let k = bloomScale
        bloomMask.lineWidth = 2 * reach / k
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(blurRadius / k, forKey: kCIInputRadiusKey)
            bloomContainer.filters = [blur]
        }
        coreContainer.shadowRadius = 4 + 26 * glow
    }

    /// Called every frame. `master` fades the whole rim, `punch` is a short kick on each beat,
    /// `comet` swaps the two-color wrap for a bright head with a fading tail.
    func render(primary p: NSColor, secondary s: NSColor, level: CGFloat, angle: CGFloat,
                master: CGFloat = 1, punch: CGFloat = 0, comet: Bool = false, cometCount: Int = 2, wavy: Bool = false,
                dt: CGFloat = 1.0 / 60, edgeColors: [SIMD3<Float>]? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if abs(thickness - targetThickness) > 0.02 || abs(glow - targetGlow) > 0.002 {
            thickness += (targetThickness - thickness) * 0.18
            glow += (targetGlow - glow) * 0.18
            applyGeometry()
        }
        // A short white flash on each beat makes the hits feel like they land.
        let flash = min(0.4, 0.4 * punch)
        let p = flash > 0.01 ? (p.blended(withFraction: flash, of: .white) ?? p) : p
        let s = flash > 0.01 ? (s.blended(withFraction: flash * 0.6, of: .white) ?? s) : s

        if comet != cometActive {
            cometActive = comet
            coreContainer.mask = comet ? cornerMasks[0] : nil
            bloomContainer.mask = comet ? cornerMasks[1] : nil
        }

        let colors: [CGColor]
        let locations: [NSNumber]?
        if let ring = edgeColors, ring.count > 1 {
            // Movie mode: one stop per screen-edge sample, wrapping back to the first.
            if movieLocations.count != ring.count + 1 {
                movieLocations = (0...ring.count).map { NSNumber(value: Double($0) / Double(ring.count)) }
            }
            colors = (ring + [ring[0]]).map { CGColor(srgbRed: CGFloat($0.x), green: CGFloat($0.y), blue: CGFloat($0.z), alpha: 1) }
            locations = movieLocations
        } else if comet {
            // Two comets: a sharp bright head and a long tail that fades out behind it.
            let head = p.blended(withFraction: 0.5, of: .white) ?? p
            let n = max(1, cometCount)
            var cs: [CGColor] = [], ls: [NSNumber] = []
            for i in 0..<n {
                let stops: [(CGFloat, NSColor)] = [
                    (0, p.withAlphaComponent(0.0)), (0.5, s.withAlphaComponent(0.35)),
                    (0.82, p.withAlphaComponent(0.8)), (0.97, p), (0.995, head),
                ]
                for (loc, c) in stops {
                    cs.append(c.cgColor)
                    ls.append(NSNumber(value: Double((CGFloat(i) + loc) / CGFloat(n))))
                }
            }
            cs.append(p.withAlphaComponent(0.0).cgColor)
            ls.append(1)
            colors = cs
            locations = ls
        } else {
            colors = [p.cgColor, s.cgColor, p.cgColor]
            locations = nil
        }
        // Movie colors are tied to screen positions, so the gradient must not rotate.
        let end = edgeColors == nil ? CGPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle))
                                    : CGPoint(x: 0.5, y: 1)

        coreGradient.colors = colors
        coreGradient.locations = locations
        coreGradient.endPoint = end
        let band = thickness * (0.7 + 0.6 * level) * (1 + 0.55 * punch)
        // The blurred bloom is the expensive part: refresh it less often than the sharp band
        // (every other frame while spinning, so the rotation doesn't look steppy).
        frameCount += 1
        let refreshBloom = frameCount % (comet || edgeColors != nil ? 2 : (wavy ? 3 : 6)) == 0 || bloomGradient.colors == nil
        waveGain += ((wavy ? 1 : 0) - waveGain) * 0.1
        if waveGain < 0.01 { waveGain = 0 }
        if waveGain > 0, !edge.isEmpty {
            // History is kept at 60 samples a second whatever the real frame rate.
            let steps = max(1, Int((dt * 60).rounded()))
            history.removeFirst(steps)
            history.append(contentsOf: repeatElement(min(1, level + 0.5 * punch), count: steps))
            let amp = (3 + 1.1 * thickness) * waveGain
            let t = CACurrentMediaTime()
            let wave: [CGFloat] = edge.dist.map { d in
                let h = history[history.count - 1 - min(history.count - 1, Int(d / 13))]
                let ripple = 0.5 + 0.5 * sin(2 * .pi * (d / 260 - CGFloat(t) * 0.7))
                return amp * (0.7 * h + 0.3 * level * ripple)
            }
            let peak = wave.max() ?? 0
            // Constant stroke width; the centreline moves so the inner edge sits at band + wave.
            coreMask.lineWidth = 2 * (band + peak)
            coreMask.path = edge.path(offsets: wave.map { $0 - peak })
            if refreshBloom {
                bloomMask.path = edge.path(offsets: wave.map { $0 * 0.6 }, scale: 1 / bloomScale)
            }
            waveActive = true
        } else {
            coreMask.lineWidth = 2 * band
            if waveActive {
                waveActive = false
                coreMask.path = basePath
                bloomMask.path = bloomBasePath
            }
        }
        coreContainer.opacity = Float(min(1, (0.35 + 0.65 * level + 0.2 * punch) * master))
        coreContainer.shadowColor = p.cgColor
        coreContainer.shadowRadius = (4 + 26 * glow) * (1 + 0.5 * punch)
        coreContainer.shadowOpacity = borderOnly ? 0 : Float(min(1, (0.3 + 0.7 * glow) * master))

        if refreshBloom {
            bloomGradient.colors = colors
            bloomGradient.locations = locations
            bloomGradient.endPoint = end
        }
        let haloGain = borderOnly ? 0.45 + 0.4 * glow : glow
        bloomContainer.opacity = Float(min(1, haloGain * (0.1 + 0.6 * level + 0.3 * punch) * master * (borderOnly ? 1.4 : 1)))

        CATransaction.commit()
    }

    /// Alpha mask that dims the rim near the four corners (a comet whips round them much faster
    /// than along the edges), but only down to `floor` so the spin is still felt.
    static func cornerFade(size: CGSize, floor: CGFloat = 0.4) -> CGImage? {
        let w = max(1, Int(size.width / 2)), h = max(1, Int(size.height / 2))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let grad = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
                                    colorComponents: [0, floor, 0, 1], locations: [0, 1], count: 2)
        else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let r = CGFloat(min(w, h)) * 0.34
        ctx.setBlendMode(.copy)
        for c in [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)] {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Rounded rectangle along the display edge, dipping around the notch if there is one.
    static func edgePath(in b: CGRect, radius: CGFloat, notch: CGRect?) -> CGPath {
        let r = max(0, min(radius, min(b.width, b.height) / 4))
        let p = CGMutablePath()
        let top = b.maxY

        p.move(to: CGPoint(x: b.minX + r, y: top))
        if let n = notch, n.width > 20 {
            let nr: CGFloat = min(8, n.height / 2)
            p.addLine(to: CGPoint(x: n.minX - nr, y: top))
            p.addQuadCurve(to: CGPoint(x: n.minX, y: top - nr), control: CGPoint(x: n.minX, y: top))
            p.addLine(to: CGPoint(x: n.minX, y: n.minY + nr))
            p.addQuadCurve(to: CGPoint(x: n.minX + nr, y: n.minY), control: CGPoint(x: n.minX, y: n.minY))
            p.addLine(to: CGPoint(x: n.maxX - nr, y: n.minY))
            p.addQuadCurve(to: CGPoint(x: n.maxX, y: n.minY + nr), control: CGPoint(x: n.maxX, y: n.minY))
            p.addLine(to: CGPoint(x: n.maxX, y: top - nr))
            p.addQuadCurve(to: CGPoint(x: n.maxX + nr, y: top), control: CGPoint(x: n.maxX, y: top))
        }
        p.addLine(to: CGPoint(x: b.maxX - r, y: top))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: top), tangent2End: CGPoint(x: b.maxX, y: top - r), radius: r)
        p.addLine(to: CGPoint(x: b.maxX, y: b.minY + r))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX - r, y: b.minY), radius: r)
        p.addLine(to: CGPoint(x: b.minX + r, y: b.minY))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.minX, y: b.minY + r), radius: r)
        p.addLine(to: CGPoint(x: b.minX, y: top - r))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: top), tangent2End: CGPoint(x: b.minX + r, y: top), radius: r)
        p.closeSubpath()
        return p
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    /// The notch cut-out in this screen's own coordinates (origin bottom-left), if any.
    var notchRect: CGRect? {
        let h = safeAreaInsets.top
        guard h > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let x0 = left.width
        let x1 = frame.width - right.width
        guard x1 > x0 else { return nil }
        return CGRect(x: x0, y: frame.height - h, width: x1 - x0, height: h)
    }
}
