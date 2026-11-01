import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let analyzer = BeatAnalyzer()
    private lazy var tap = SystemAudioTap(analyzer: analyzer)
    private let nowPlaying = NowPlayingWatcher()
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem!
    private var audioStatus = "Audio: off"
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController(settings: settings, analyzer: analyzer)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "rays", accessibilityDescription: "Glowrim")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        nowPlaying.onArtwork = { [weak self] image in
            guard let self, let palette = ColorExtractor.palette(from: image) else { return }
            self.overlay.albumColors = palette
        }

        tap.onDeviceChange = { [weak self] in
            Task { @MainActor in self?.restartAudio() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)

        overlay.onSleepChange = { [weak self] _ in self?.apply() }
        overlay.onStatusChange = { [weak self] in self?.refreshStatus() }
        settings.onChange = { [weak self] in self?.apply() }
        apply()
        nowPlaying.refresh()
    }

    private func apply() {
        overlay.settingsChanged()
        analyzer.sensitivity = Float(settings.sensitivity)

        let wantAudio = settings.enabled && !overlay.asleep && (settings.mode == .music || settings.mode == .spinning)
        if wantAudio, !tap.running {
            do {
                try tap.start()
                audioStatus = "Listening to system audio"
            } catch {
                audioStatus = "Audio unavailable: \(error)"
            }
        } else if !wantAudio, tap.running {
            tap.stop()
            audioStatus = "Audio: off"
        }
        refreshStatus()
    }

    private func refreshStatus() {
        guard settings.enabled else { settings.statusText = "Off"; return }
        switch settings.mode {
        case .music, .spinning: settings.statusText = audioStatus
        case .movie: settings.statusText = overlay.captureStatus
        case .breathe, .steady: settings.statusText = ""
        }
    }

    private func restartAudio() {
        guard tap.running else { return }
        tap.stop()
        apply()
    }

    @objc private func didWake() {
        restartAudio()
        nowPlaying.refresh()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Glowrim", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !settings.statusText.isEmpty {
            let status = NSMenuItem(title: settings.statusText, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        menu.addItem(.separator())
        menu.addItem(item("Enabled", #selector(toggleEnabled), checked: settings.enabled, key: "e"))
        menu.addItem(.separator())

        for (title, category) in [("Movie presets", PresetCategory.movie), ("Music presets", .music)] {
            menu.addItem(NSMenuItem.sectionHeader(title: title))
            for p in Settings.presets where p.category == category {
                let i = item(p.name, #selector(pickPreset(_:)), checked: settings.presetID == p.id)
                i.representedObject = p.id
                i.image = swatch(NSColor(hex: p.preview.0)!, NSColor(hex: p.preview.1)!)
                menu.addItem(i)
            }
        }
        menu.addItem(NSMenuItem.sectionHeader(title: "Custom"))
        menu.addItem(item("Custom…", #selector(pickCustom), checked: settings.presetID == Settings.customID))

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Glowrim", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, checked: Bool? = nil, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let checked { i.state = checked ? .on : .off }
        return i
    }

    /// A small round color chip (or a two-color split) for menu items.
    private func swatch(_ a: NSColor, _ b: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let circle = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            NSGradient(starting: a, ending: b)?.draw(in: circle, angle: 45)
            NSColor.white.withAlphaComponent(0.35).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
    }

    // MARK: - Actions

    private func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    @objc private func toggleEnabled() { tick(); settings.enabled.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        tick()
        if let id = sender.representedObject as? String, let p = Settings.presets.first(where: { $0.id == id }) {
            settings.apply(p)
        }
    }

    @objc private func pickCustom() {
        tick()
        settings.presetID = Settings.customID
        openSettings()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(s: settings)))
            window.title = "Glowrim Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 780))
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(hex: "#0A0604")
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
