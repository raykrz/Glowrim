import SwiftUI
import ServiceManagement

/// The settings window: pick a preset, or choose Custom to build your own look.
struct SettingsView: View {
    @ObservedObject var s: Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var isCustom: Bool { s.presetID == Settings.customID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                presetSection("Movie presets", "The rim takes its colors from what's on screen.", .movie)
                presetSection("Music presets", "The rim moves with whatever you're playing.", .music)
                customSection
                generalSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 600, minHeight: 620)
        .background(
            ZStack(alignment: .top) {
                Brand.bg
                // Warm light spilling down from the top edge, like the rim itself.
                RadialGradient(colors: [Brand.ember.opacity(0.30), Brand.ember2.opacity(0.08), .clear],
                               center: .top, startRadius: 0, endRadius: 460)
                    .frame(height: 520)
            }
            .ignoresSafeArea())
        .tint(Brand.ember)
        .preferredColorScheme(.dark)
        .animation(.snappy(duration: 0.25), value: s.presetID)
        .animation(.snappy(duration: 0.25), value: s.mode)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Brand.ember, Brand.ember2], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Brand.ember.opacity(0.55), radius: 14)
                Image(systemName: "rays").font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Glowrim").font(.system(size: 24, weight: .semibold))
                if !s.statusText.isEmpty {
                    HStack(spacing: 6) {
                        Circle().fill(statusIsGood ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(s.statusText).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: $s.enabled)
                .toggleStyle(.switch)
        }
    }

    private var statusIsGood: Bool {
        s.statusText.hasPrefix("Listening") || s.statusText.hasPrefix("Following")
    }

    // MARK: Presets

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func presetSection(_ title: String, _ subtitle: String, _ category: PresetCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, subtitle)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(Settings.presets.filter { $0.category == category }) { p in
                    PresetCard(preset: p, selected: s.presetID == p.id) { s.apply(p) }
                }
            }
        }
    }

    // MARK: Custom

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Custom", "Pick the animation, colors and more yourself.")

            Button { s.presetID = Settings.customID } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Build your own").font(.system(size: 13, weight: .semibold))
                        Text(isCustom ? "Starts from your current look" : "Tap to fine-tune everything")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isCustom { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.ember) }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .cardBackground(selected: isCustom)
            }
            .buttonStyle(.plain)

            if isCustom {
                customPanel.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var customPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Animation") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(GlowMode.allCases, id: \.self) { m in
                        Chip(title: m.title, symbol: m.symbol, selected: s.mode == m) { s.mode = m }
                    }
                }
                if s.mode == .spinning {
                    row("Comets") {
                        Picker("", selection: $s.cometCount) {
                            ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Spacer()
                    }
                }
                if s.mode == .movie {
                    hint("Movie mode reads a tiny capture of your screen. macOS asks for Screen Recording the first time.")
                }
            }

            group("Look") {
                row("Style") {
                    Picker("", selection: $s.style) {
                        ForEach(GlowStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                row("Wavy edge") {
                    Toggle("", isOn: $s.wavy).toggleStyle(.switch).labelsHidden()
                    Text("The inner edge ripples with the beat").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                sliderRow("Thickness", $s.thickness, 2...30) { String(format: "%.0f pt", $0) }
                sliderRow("Glow", $s.glow, 0...1) { String(format: "%.0f%%", $0 * 100) }
                if s.mode == .music || s.mode == .spinning {
                    sliderRow("Beat sensitivity", $s.sensitivity, 0...1) { String(format: "%.0f%%", $0 * 100) }
                }
            }

            if s.mode != .movie {
                group("Colors") {
                    row("Album art") {
                        Toggle("", isOn: $s.matchAlbum).toggleStyle(.switch).labelsHidden()
                        Text("Use the cover of what's playing in Spotify or Music")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    row("Your colors") {
                        ColorPicker("Primary", selection: colorBinding(\.primary)).fixedSize()
                        ColorPicker("Secondary", selection: colorBinding(\.secondary)).fixedSize()
                        Spacer()
                    }
                    row("Palettes") {
                        HStack(spacing: 8) {
                            ForEach(Settings.palettes, id: \.0) { p in
                                Button {
                                    s.matchAlbum = false
                                    s.primary = NSColor(hex: p.1)!
                                    s.secondary = NSColor(hex: p.2)!
                                } label: {
                                    Circle()
                                        .fill(LinearGradient(colors: [Color(hex: p.1), Color(hex: p.2)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 24, height: 24)
                                        .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                                .help(p.0)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("General", "Where and when the rim shows up.")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Follow the notch", isOn: $s.followNotch).toggleStyle(.switch)
                Toggle("Show on all displays", isOn: $s.allDisplays).toggleStyle(.switch)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = on
                        } catch {
                            NSSound.beep()
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }))
                .toggleStyle(.switch)
                Divider()
                Button("Reset everything to defaults") { s.resetToDefaults() }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    // MARK: Helpers

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 118, alignment: .leading)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                           _ format: @escaping (Double) -> String) -> some View {
        row(title) {
            Slider(value: value, in: range)
            Text(format(value.wrappedValue))
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func colorBinding(_ kp: ReferenceWritableKeyPath<Settings, NSColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: s[keyPath: kp]) },
                set: { s.matchAlbum = false; s[keyPath: kp] = NSColor($0).srgb })
    }
}

// MARK: - Pieces

private struct PresetCard: View {
    let preset: Preset
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: preset.preview.0), Color(hex: preset.preview.1)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: preset.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.25), radius: 4)
                }
                .frame(height: 62)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 13, weight: .semibold))
                    Text(preset.blurb).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(selected: selected, hover: hover)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.ember)
                        .background(Circle().fill(.white))
                        .padding(14)
                }
            }
            .scaleEffect(hover ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

private struct Chip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(LinearGradient(colors: [Brand.ember, Brand.ember2], startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color.white.opacity(0.07))))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func cardBackground(selected: Bool, hover: Bool = false) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(LinearGradient(colors: [Brand.ember, Brand.ember2.opacity(0.6)],
                                                                      startPoint: .top, endPoint: .bottom))
                                       : AnyShapeStyle(Color.white.opacity(hover ? 0.22 : 0.08)),
                              lineWidth: selected ? 1.8 : 1))
            .shadow(color: selected ? Brand.ember.opacity(0.35) : .clear, radius: 14)
    }
}

/// Colors taken from the ember-on-black brand: near-black warm surfaces, orange light.
enum Brand {
    static let bg = Color(hex: "#0A0604")
    static let card = Color(hex: "#15100C")
    static let ember = Color(hex: "#FF7A1A")
    static let ember2 = Color(hex: "#FF4D00")
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex) ?? .white)
    }
}
