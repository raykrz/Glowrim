import CoreGraphics

/// The screen-edge path flattened into a closed polyline with inward normals, so the rim can be
/// pushed inward point by point to form a wave.
struct EdgeContour {
    private(set) var points: [CGPoint] = []
    private var normals: [CGPoint] = []
    /// Distance along the edge (the shorter way round) from the wave source.
    private(set) var dist: [CGFloat] = []

    init(path: CGPath, source: CGPoint) {
        var pts: [CGPoint] = []
        var cur = CGPoint.zero, start = CGPoint.zero

        func line(to p: CGPoint) {
            let n = max(1, Int((hypot(p.x - cur.x, p.y - cur.y) / 14).rounded(.up)))
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                pts.append(CGPoint(x: cur.x + (p.x - cur.x) * t, y: cur.y + (p.y - cur.y) * t))
            }
            cur = p
        }

        path.applyWithBlock { e in
            let el = e.pointee, p = el.points
            switch el.type {
            case .moveToPoint:
                cur = p[0]; start = cur; pts.append(cur)
            case .addLineToPoint:
                line(to: p[0])
            case .addQuadCurveToPoint:
                let c = p[0], end = p[1], from = cur
                for i in 1...6 {
                    let t = CGFloat(i) / 6, u = 1 - t
                    pts.append(CGPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * end.x,
                                       y: u * u * from.y + 2 * u * t * c.y + t * t * end.y))
                }
                cur = end
            case .addCurveToPoint:
                let c1 = p[0], c2 = p[1], end = p[2], from = cur
                for i in 1...8 {
                    let t = CGFloat(i) / 8, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    pts.append(CGPoint(x: a * from.x + b * c1.x + c * c2.x + d * end.x,
                                       y: a * from.y + b * c1.y + c * c2.y + d * end.y))
                }
                cur = end
            case .closeSubpath:
                line(to: start)
            @unknown default:
                break
            }
        }
        if pts.count > 1, hypot(pts[0].x - pts[pts.count - 1].x, pts[0].y - pts[pts.count - 1].y) < 0.01 {
            pts.removeLast()
        }
        guard pts.count > 3 else { return }
        points = pts

        let n = pts.count
        // The path runs clockwise (y up), so the inside of the screen is to the right of travel.
        normals = (0..<n).map { i in
            let a = pts[(i + n - 1) % n], b = pts[(i + 1) % n]
            let tx = b.x - a.x, ty = b.y - a.y
            let len = max(hypot(tx, ty), 0.0001)
            return CGPoint(x: ty / len, y: -tx / len)
        }

        var s: [CGFloat] = [0]
        for i in 1..<n { s.append(s[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = s[n - 1] + hypot(pts[0].x - pts[n - 1].x, pts[0].y - pts[n - 1].y)
        let src = pts.indices.min { hypot(pts[$0].x - source.x, pts[$0].y - source.y)
                                  < hypot(pts[$1].x - source.x, pts[$1].y - source.y) } ?? 0
        dist = s.map { let d = abs($0 - s[src]); return min(d, total - d) }
    }

    var isEmpty: Bool { points.isEmpty }

    /// The polyline with every point pushed inward by `offsets[i]` (negative = toward the bezel).
    func path(offsets: [CGFloat], scale: CGFloat = 1) -> CGPath {
        let p = CGMutablePath()
        for i in points.indices {
            let q = CGPoint(x: (points[i].x + normals[i].x * offsets[i]) * scale,
                            y: (points[i].y + normals[i].y * offsets[i]) * scale)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }
}
