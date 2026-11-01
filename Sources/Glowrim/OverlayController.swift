import AppKit

/// Owns the overlay windows and drives the animation at 60 fps.
@MainActor
final class OverlayController: NSObject {
    private let settings: Settings
    private let analyzer: BeatAnalyzer

    private var windows: [OverlayWindow] = []
    private var timer: Timer?
    private var layoutKey = ""

    var albumColors: (NSColor, NSColor)? { didSet { dirtyTime = 3 } }
    private var curP: NSColor
    private var curS: NSColor
    private var level: CGFloat = 0
    private var angle: CGFloat = .pi / 2
    private var phase: Double = 0
    private var speed: CGFloat = 0
    private var punch: CGFloat = 0
    private var lastLevel: CGFloat = 0
    /// 0...1 fade of the whole rim: eases in when enabled, out before the windows go away.
    private var master: CGFloat = 0
    private var fadingOut = false
    private var silentTime: Double = 0
    private var dirtyTime: Double = 0 // keeps rendering briefly after any settings change
    private var lastTick = CACurrentMediaTime()
    private var currentFPS: Double = 0
    private(set) var asleep = false
    var onSleepChange: ((Bool) -> Void)?

    // Movie mode
    private var samplers: [CGDirectDisplayID: ScreenSampler] = [:]
    private var shownRing: [CGDirectDisplayID: [SIMD3<Float>]] = [:]
    private(set) var captureStatus = "" { didSet { if captureStatus != oldValue { onStatusChange?() } } }
    var onStatusChange: (() -> Void)?
    private var idle: CGFloat = 0 // 0 = music playing, 1 = silent for a while

    init(settings: Settings, analyzer: BeatAnalyzer) {
        self.settings = settings
        self.analyzer = analyzer
        curP = settings.primary
        curS = settings.secondary
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(displaysSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(displaysWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private func screensChanged() {
        layoutKey = "" // force rebuild
        settingsChanged()
    }

    func settingsChanged() {
        guard settings.enabled else {
            if timer == nil { teardown() } else { fadingOut = true }
            return
        }
        fadingOut = false
        dirtyTime = 1.5

        let key = "\(settings.followNotch)-\(settings.allDisplays)-\(NSScreen.screens.count)"
        if key != layoutKey || windows.isEmpty {
            layoutKey = key
            buildWindows()
        }
        for w in windows {
            w.glowView.configure(thickness: CGFloat(settings.thickness), glow: CGFloat(settings.glow),
                                 borderOnly: settings.style == .border)
        }
        startTimer()
        syncSamplers()
    }

    /// Movie mode only: capture each overlaid display at a tiny size; otherwise capture nothing.
    private func syncSamplers() {
        let want = settings.enabled && settings.mode == .movie && !asleep && !fadingOut
        guard want else {
            samplers.values.forEach { $0.stop() }
            samplers.removeAll()
            shownRing.removeAll()
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            captureStatus = "Movie needs Screen Recording: allow Glowrim in System Settings → Privacy & Security"
        }
        let ids = Set(windows.map(\.displayID))
        for (id, s) in samplers where !ids.contains(id) {
            s.stop(); samplers[id] = nil; shownRing[id] = nil
        }
        for id in ids where samplers[id] == nil {
            let sampler = ScreenSampler(displayID: id)
            samplers[id] = sampler
            Task { [weak self] in
                do {
                    try await sampler.start()
                    self?.captureStatus = "Following the screen"
                } catch {
                    self?.captureStatus = "Screen capture unavailable: allow Glowrim in Screen Recording settings"
                    if self?.samplers[id] === sampler { self?.samplers[id] = nil }
                }
            }
        }
    }

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        var screens = NSScreen.screens
        if !settings.allDisplays {
            if let builtIn = screens.first(where: { $0.isBuiltIn }) {
                screens = [builtIn]
            } else if let main = NSScreen.main {
                screens = [main]
            }
        }

        for screen in screens {
            let w = OverlayWindow(screen: screen)
            w.glowView.cornerRadius = screen.isBuiltIn ? 10 : 0
            w.glowView.notch = settings.followNotch ? screen.notchRect : nil
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    private func teardown() {
        samplers.values.forEach { $0.stop() }
        samplers.removeAll()
        shownRing.removeAll()
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        layoutKey = ""
        fadingOut = false
        master = 0
        currentFPS = 0
    }

    // MARK: - Frame pacing

    /// Frames per second the current look actually needs. Everything else idles.
    private var desiredFPS: Double {
        var fps: Double
        switch settings.mode {
        case .spinning: fps = 60
        case .music: fps = silentTime > 0.6 ? 30 : 60
        case .breathe: fps = 30
        case .movie: fps = 30
        case .steady: fps = settings.wavy ? 30 : (isStatic ? 6 : 60)
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { fps = min(fps, 30) }
        return fps
    }

    /// Steady, no wave, and everything has settled: there is nothing to redraw.
    private var isStatic: Bool {
        settings.mode == .steady && !settings.wavy && !fadingOut && dirtyTime <= 0
            && master > 0.999 && abs(level - 0.75) < 0.002 && speed < 0.002 && punch < 0.005
            && curP.distance(to: wanted.0) < 0.003 && curS.distance(to: wanted.1) < 0.003
    }

    private var wanted: (NSColor, NSColor) {
        (settings.matchAlbum ? albumColors : nil) ?? (settings.primary, settings.secondary)
    }

    private func startTimer() {
        guard timer == nil, !asleep else { return }
        schedule(fps: desiredFPS)
    }

    private func schedule(fps: Double) {
        timer?.invalidate()
        let t = Timer(timeInterval: 1 / fps, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.15 / fps // lets the system coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
        currentFPS = fps
        lastTick = CACurrentMediaTime()
    }

    @objc private func displaysSlept() {
        asleep = true
        timer?.invalidate()
        timer = nil
        syncSamplers()
        onSleepChange?(true)
    }

    @objc private func displaysWoke() {
        asleep = false
        onSleepChange?(false)
        if settings.enabled, !windows.isEmpty { startTimer(); syncSamplers() }
    }

    @objc private func tick() {
        // Real elapsed time, so the motion is the same speed at 60, 30 or 6 fps.
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(1.0 / 120, now - lastTick))
        lastTick = now
        let frames = CGFloat(dt * 60)
        /// Per-frame smoothing factor (tuned at 60 fps) converted to this frame's length.
        func k(_ perFrame: CGFloat) -> CGFloat { 1 - pow(1 - perFrame, frames) }

        phase += dt
        dirtyTime = max(0, dirtyTime - dt)

        // After a moment of silence the rim drifts into a slow breath instead of freezing flat.
        silentTime = analyzer.level < 0.03 ? silentTime + dt : 0
        idle += ((silentTime > 1.5 ? 1 : 0) - idle) * k(0.03)
        let drift = idle * 0.16 * CGFloat(0.5 + 0.5 * sin(phase * 2 * .pi / 4))

        let target: CGFloat
        switch settings.mode {
        case .music:
            target = max(CGFloat(analyzer.level), 0.12 + drift)
        case .spinning:
            target = max(CGFloat(analyzer.level), 0.26 + drift)
        case .breathe:
            target = 0.3 + 0.5 * CGFloat(0.5 + 0.5 * sin(phase * 2 * .pi / 5))
        case .steady:
            target = 0.75
        case .movie:
            target = 0.8
        }
        level += (target - level) * k(target > level ? 0.55 : 0.12)

        // A sudden jump in level is a beat: kick the thickness and let it fall back smoothly.
        if settings.mode == .music || settings.mode == .spinning, level - lastLevel > 0.06 {
            punch = max(punch, min(1, (level - lastLevel) * 6))
        }
        lastLevel = level
        punch *= pow(0.86, frames)

        master += ((fadingOut ? 0 : 1) - master) * k(0.07)
        if fadingOut, master < 0.01 {
            master = 0
            teardown()
            return
        }

        let colors = wanted
        curP = curP.lerp(to: colors.0, k(0.05))
        curS = curS.lerp(to: colors.1, k(0.05))

        let targetSpeed: CGFloat
        switch settings.mode {
        case .music: targetSpeed = 0.15 + 1.2 * level
        case .breathe: targetSpeed = 0.12
        case .steady, .movie: targetSpeed = 0
        case .spinning: targetSpeed = 0.9 + 3.2 * level // comets race on the beat
        }
        speed += (targetSpeed - speed) * k(0.04) // spin up and wind down instead of snapping
        angle += speed * CGFloat(dt)

        // Movie: ease each display's edge colors toward the newest capture.
        if settings.mode == .movie {
            for w in windows {
                guard let raw = samplers[w.displayID]?.colors else { continue }
                if var shown = shownRing[w.displayID], shown.count == raw.count {
                    let f = Float(k(0.22))
                    for i in shown.indices { shown[i] += (raw[i] - shown[i]) * f }
                    shownRing[w.displayID] = shown
                } else {
                    shownRing[w.displayID] = raw
                }
            }
            if let first = windows.first, let ring = shownRing[first.displayID], !ring.isEmpty {
                let avg = ring.reduce(SIMD3<Float>.zero, +) / Float(ring.count)
                curP = NSColor(srgbRed: CGFloat(avg.x), green: CGFloat(avg.y), blue: CGFloat(avg.z), alpha: 1)
                curS = curP
            }
        }

        if !isStatic {
            for w in windows {
                w.glowView.render(primary: curP, secondary: curS, level: level, angle: angle,
                                  master: master, punch: punch, comet: settings.mode == .spinning,
                                  cometCount: settings.cometCount, wavy: settings.wavy, dt: CGFloat(dt),
                                  edgeColors: settings.mode == .movie ? shownRing[w.displayID] : nil)
            }
        }

        let fps = desiredFPS
        if fps != currentFPS { schedule(fps: fps) }
    }
}
