import AppKit
import CoreMedia
import ScreenCaptureKit

/// Movie mode: watches one display at a tiny resolution and reduces each frame to a ring of
/// edge colors, in the same order the rim's conic gradient uses (from the top, counterclockwise,
/// measured against the screen's own width and height).
final class ScreenSampler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let segments = 72

    let displayID: CGDirectDisplayID
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "glowrim.screen", qos: .userInitiated)
    private let lock = NSLock()
    private var _colors: [SIMD3<Float>]?
    private var starting = false

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    var colors: [SIMD3<Float>]? {
        lock.lock(); defer { lock.unlock() }
        return _colors
    }

    var isRunning: Bool { stream != nil || starting }

    func start() async throws {
        guard stream == nil, !starting else { return }
        starting = true
        defer { starting = false }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "Glowrim", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display not found"])
        }
        // Leave our own overlay out of the picture, or the glow would feed back into itself.
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 96
        config.height = max(16, Int((96 * Double(display.height) / Double(max(1, display.width))).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        let s = stream
        stream = nil
        lock.lock(); _colors = nil; lock.unlock()
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let bpr = CVPixelBufferGetBytesPerRow(pixels)
        let ring = Self.edgeColors(base: base.assumingMemoryBound(to: UInt8.self), width: w, height: h, bytesPerRow: bpr)

        lock.lock(); _colors = ring; lock.unlock()
    }

    /// One color per segment around the screen edge.
    static func edgeColors(base: UnsafePointer<UInt8>, width w: Int, height h: Int, bytesPerRow: Int) -> [SIMD3<Float>] {
        let m = segments
        let halfW = max(1, Int(Double(w) * 0.05)), halfH = max(1, Int(Double(h) * 0.05))

        func average(cx: Int, cy: Int) -> SIMD3<Float> {
            var sum = SIMD3<Float>(repeating: 0), n: Float = 0
            for y in max(0, cy - halfH)...min(h - 1, cy + halfH) {
                for x in max(0, cx - halfW)...min(w - 1, cx + halfW) {
                    let p = base + y * bytesPerRow + x * 4 // BGRA
                    sum += SIMD3<Float>(Float(p[2]), Float(p[1]), Float(p[0]))
                    n += 1
                }
            }
            return sum / (255 * max(1, n))
        }

        var ring = [SIMD3<Float>](repeating: .zero, count: m)
        for j in 0..<m {
            // Direction of this stop: counterclockwise from the top, in the screen's unit square.
            let phi = 2 * Double.pi * Double(j) / Double(m)
            let dx = -sin(phi), dy = cos(phi)
            let s = 0.5 / max(abs(dx), abs(dy))
            let bx = 0.5 + dx * s, by = 0.5 + dy * s

            // Start at the very edge; if it is black (letterbox bars), look further in.
            var c = SIMD3<Float>.zero
            for f in [0.12, 0.3, 0.5, 0.7] {
                let nx = bx + (0.5 - bx) * f, ny = by + (0.5 - by) * f
                let px = min(w - 1, max(0, Int(nx * Double(w))))
                let py = min(h - 1, max(0, Int((1 - ny) * Double(h)))) // image rows run top-down
                c = average(cx: px, cy: py)
                if max(c.x, c.y, c.z) > 0.08 { break }
            }
            ring[j] = c
        }

        // Soften neighbours so a busy frame doesn't shimmer, then make the colors punchy.
        return (0..<m).map { j in
            let c = ring[(j + m - 1) % m] * 0.25 + ring[j] * 0.5 + ring[(j + 1) % m] * 0.25
            return punch(c)
        }
    }

    private static func punch(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let col = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
        col.getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
        let out = NSColor(hue: hue, saturation: min(1, sat * 1.35), brightness: min(1, max(0.12, bri * 1.3)), alpha: 1).srgb
        return SIMD3<Float>(Float(out.redComponent), Float(out.greenComponent), Float(out.blueComponent))
    }
}
