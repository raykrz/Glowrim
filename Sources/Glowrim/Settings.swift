import AppKit

enum GlowMode: String, CaseIterable {
    case music, breathe, steady, spinning, movie

    var title: String {
        switch self {
        case .music: "Music sync"
        case .breathe: "Breathe"
        case .steady: "Steady"
        case .spinning: "Spinning"
        case .movie: "Movie"
        }
    }

    var symbol: String {
        switch self {
        case .music: "waveform"
        case .breathe: "wind"
        case .steady: "circle.dashed"
        case .spinning: "arrow.triangle.2.circlepath"
        case .movie: "film"
        }
    }
}

enum GlowStyle: String, CaseIterable {
    case screen, border

    var title: String {
        switch self {
        case .screen: "Border + screen glow"
        case .border: "Border only"
        }
    }
}

enum PresetCategory { case movie, music }

/// A one-click bundle of settings, shown as a card in the settings window and in the menu.
struct Preset: Identifiable {
    let id: String
    let name: String
    let blurb: String
    let symbol: String
    let category: PresetCategory
    let mode: GlowMode
    let style: GlowStyle
    let thickness: Double
    let glow: Double
    var comets = 2
    var wavy = false
    var matchAlbum = true
    var colors: (String, String)? = nil   // fixed colors; nil keeps the user's / album colors
    let preview: (String, String)         // gradient shown on the card
}

/// Persistent settings backed by UserDefaults. Every write calls `onChange` and refreshes the UI.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    static let customID = "custom"

    static let presets: [Preset] = [
        Preset(id: "movie.cinema", name: "Cinema", blurb: "Wide, immersive glow", symbol: "film",
               category: .movie, mode: .movie, style: .screen, thickness: 12, glow: 0.85,
               preview: ("#FF8A3D", "#3D6BFF")),
        Preset(id: "movie.ambient", name: "Ambient", blurb: "Soft, tight halo", symbol: "moon.stars",
               category: .movie, mode: .movie, style: .border, thickness: 6, glow: 0.5,
               preview: ("#4F7BFF", "#9B5CFF")),
        Preset(id: "movie.vivid", name: "Vivid", blurb: "Big, bold color", symbol: "sparkles.tv",
               category: .movie, mode: .movie, style: .screen, thickness: 16, glow: 1.0, wavy: true,
               preview: ("#FF2E9A", "#FFB400")),

        Preset(id: "music.pulse", name: "Pulse", blurb: "Beat-synced glow, rippling edge", symbol: "waveform",
               category: .music, mode: .music, style: .screen, thickness: 12, glow: 0.6, wavy: true,
               preview: ("#FF4FA3", "#4F7BFF")),
        Preset(id: "music.party", name: "Party", blurb: "Three comets racing on the beat", symbol: "party.popper",
               category: .music, mode: .spinning, style: .screen, thickness: 10, glow: 0.8, comets: 3, wavy: true,
               preview: ("#FFB400", "#FF2E9A")),
        Preset(id: "music.neon", name: "Neon", blurb: "Cyan and magenta comets", symbol: "bolt.fill",
               category: .music, mode: .spinning, style: .border, thickness: 6, glow: 0.9, matchAlbum: false,
               colors: ("#00F5FF", "#FF2BD6"), preview: ("#00F5FF", "#FF2BD6")),
        Preset(id: "music.comet", name: "Comet", blurb: "One long trail, chasing the beat", symbol: "sparkle",
               category: .music, mode: .spinning, style: .screen, thickness: 8, glow: 0.7, comets: 1, wavy: false,
               preview: ("#7FB8FF", "#FF5E62")),
        Preset(id: "music.chill", name: "Chill", blurb: "Slow, breathing light", symbol: "leaf",
               category: .music, mode: .breathe, style: .screen, thickness: 6, glow: 0.75, wavy: true,
               preview: ("#00C6FF", "#9B5CFF")),
        Preset(id: "music.minimal", name: "Minimal", blurb: "A calm, thin line", symbol: "minus",
               category: .music, mode: .steady, style: .border, thickness: 3, glow: 0.3,
               preview: ("#E0F7FF", "#7FB8FF")),
    ]

    /// Color pairs offered in the custom panel.
    static let palettes: [(String, String, String)] = [
        ("Sunset", "#FF5E62", "#FFB347"),
        ("Ocean", "#00C6FF", "#0072FF"),
        ("Aurora", "#00F5A0", "#9B5CFF"),
        ("Ember", "#FF2E2E", "#FF8A00"),
        ("Ice", "#E0F7FF", "#7FB8FF"),
        ("Candy", "#FF4FA3", "#4F7BFF"),
    ]

    /// Text for the status line (audio / screen capture state), set by the app delegate.
    var statusText = "" { didSet { objectWillChange.send() } }

    /// The selected preset's id, or "custom".
    var presetID: String {
        get { d.string(forKey: "preset") ?? "music.pulse" }
        set { store(newValue, "preset") }
    }

    func apply(_ p: Preset) {
        let cb = onChange
        onChange = nil // apply everything, then refresh once
        mode = p.mode; style = p.style
        thickness = p.thickness; glow = p.glow
        cometCount = p.comets; wavy = p.wavy
        matchAlbum = p.matchAlbum
        if let c = p.colors {
            primary = NSColor(hex: c.0)!; secondary = NSColor(hex: c.1)!
        }
        presetID = p.id
        onChange = cb
        onChange?()
    }

    func resetToDefaults() {
        for k in ["preset", "mode", "style", "matchAlbum", "primary", "secondary", "thickness", "glow",
                  "sensitivity", "cometCount", "wavy", "followNotch", "allDisplays"] {
            d.removeObject(forKey: k)
        }
        objectWillChange.send()
        onChange?()
    }

    var onChange: (() -> Void)?
    private let d = UserDefaults.standard

    private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    private func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
    private func store(_ v: Any, _ k: String) { objectWillChange.send(); d.set(v, forKey: k); onChange?() }

    var enabled: Bool {
        get { bool("enabled", true) }
        set { store(newValue, "enabled") }
    }
    var mode: GlowMode {
        get { GlowMode(rawValue: d.string(forKey: "mode") ?? "") ?? .music }
        set { store(newValue.rawValue, "mode") }
    }
    var style: GlowStyle {
        get { GlowStyle(rawValue: d.string(forKey: "style") ?? "") ?? .screen }
        set { store(newValue.rawValue, "style") }
    }
    var matchAlbum: Bool {
        get { bool("matchAlbum", true) }
        set { store(newValue, "matchAlbum") }
    }
    var primary: NSColor {
        get { NSColor(hex: d.string(forKey: "primary") ?? "") ?? NSColor(hex: "#FF4FA3")! }
        set { store(newValue.hex, "primary") }
    }
    var secondary: NSColor {
        get { NSColor(hex: d.string(forKey: "secondary") ?? "") ?? NSColor(hex: "#4F7BFF")! }
        set { store(newValue.hex, "secondary") }
    }
    /// Band thickness in points (2...30).
    var thickness: Double {
        get { dbl("thickness", 8) }
        set { store(newValue, "thickness") }
    }
    /// How far the light spills into the screen (0...1).
    var glow: Double {
        get { dbl("glow", 0.6) }
        set { store(newValue, "glow") }
    }
    /// Beat sensitivity (0...1).
    var sensitivity: Double {
        get { dbl("sensitivity", 0.5) }
        set { store(newValue, "sensitivity") }
    }
    /// Number of comets in Spinning mode (1...4).
    var cometCount: Int {
        get { min(4, max(1, d.object(forKey: "cometCount") as? Int ?? 2)) }
        set { store(newValue, "cometCount") }
    }
    /// The inner edge ripples with the music.
    var wavy: Bool {
        get { bool("wavy", true) }
        set { store(newValue, "wavy") }
    }
    var followNotch: Bool {
        get { bool("followNotch", true) }
        set { store(newValue, "followNotch") }
    }
    var allDisplays: Bool {
        get { bool("allDisplays", false) }
        set { store(newValue, "allDisplays") }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var srgb: NSColor { usingColorSpace(.sRGB) ?? .white }

    var hex: String {
        let c = srgb
        func b(_ x: CGFloat) -> Int { Int(max(0, min(255, (x * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }

    /// Largest per-channel difference (0...1) to another color.
    func distance(to other: NSColor) -> CGFloat {
        let a = srgb, o = other.srgb
        return max(abs(a.redComponent - o.redComponent), abs(a.greenComponent - o.greenComponent),
                   abs(a.blueComponent - o.blueComponent))
    }

    func lerp(to other: NSColor, _ t: CGFloat) -> NSColor {
        let a = srgb, o = other.srgb
        return NSColor(srgbRed: a.redComponent + (o.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (o.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (o.blueComponent - a.blueComponent) * t,
                       alpha: 1)
    }
}
