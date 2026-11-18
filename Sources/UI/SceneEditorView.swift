import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

private struct SceneLivePreviewWebView: NSViewRepresentable {
    let config: SceneProjectConfig

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        loadPreview(into: wv)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastConfig != config {
            context.coordinator.lastConfig = config
            loadPreview(into: nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(lastConfig: config)
    }

    private func loadPreview(into webView: WKWebView) {
        let imgSrc: String?
        if let path = config.backgroundImagePath, FileManager.default.fileExists(atPath: path) {
            imgSrc = URL(fileURLWithPath: path).absoluteString
        } else {
            imgSrc = nil
        }
        let html = SceneExporter.generateHTML(config: config, imageRelativeSrc: imgSrc)
        let baseURL = config.backgroundImagePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator {
        var lastConfig: SceneProjectConfig
        init(lastConfig: SceneProjectConfig) { self.lastConfig = lastConfig }
    }
}

public struct SceneEditorView: View {
    @ObservedObject var store = WallpaperStore.shared
    @State private var config = SceneProjectConfig()
    @State private var exportStatus: String? = nil

    public var onSavedAndApplied: ((WallpaperItem) -> Void)?

    public init(onSavedAndApplied: ((WallpaperItem) -> Void)? = nil) {
        self.onSavedAndApplied = onSavedAndApplied
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("2D Scene Editor")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Compose animated wallpapers from any image with parallax, particles, clock & audio effects.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    Button(action: pickBackgroundImage) {
                        Label(config.backgroundImagePath == nil ? "Pick Background Image..." : "Change Image...", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.bordered)

                    Button(action: saveAndApply) {
                        Label("Save & Apply", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let status = exportStatus {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text(status)
                            .font(.caption)
                        Spacer()
                        Button("Dismiss") { exportStatus = nil }
                            .buttonStyle(.plain)
                            .font(.caption)
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.14))
                    .cornerRadius(8)
                }

                SceneLivePreviewWebView(config: config)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Label("Move cursor over preview to test Mouse Parallax", systemImage: "cursorarrow.motionlines")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if config.backgroundImagePath != nil {
                        Button("Clear Image") {
                            config.backgroundImagePath = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("SCENE LAYERS & EFFECTS")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)

                    TextField("Scene Title", text: $config.title)
                        .textFieldStyle(.roundedBorder)

                    GroupBox("Motion & Camera") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Mouse Parallax Tilt", isOn: $config.parallaxEnabled)
                            if config.parallaxEnabled {
                                HStack {
                                    Text("Strength").font(.caption)
                                    Slider(value: $config.parallaxStrength, in: 0...45)
                                }
                            }

                            Toggle("Breathing / Pulse Zoom", isOn: $config.breathingEnabled)
                            if config.breathingEnabled {
                                HStack {
                                    Text("Depth").font(.caption)
                                    Slider(value: $config.breathingStrength, in: 0.005...0.08)
                                }
                            }

                            Toggle("Water Ripple Shimmer", isOn: $config.rippleEnabled)
                            if config.rippleEnabled {
                                HStack {
                                    Text("Intensity").font(.caption)
                                    Slider(value: $config.rippleIntensity, in: 0.1...1.0)
                                }
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("Particle System") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Preset", selection: $config.particlePreset) {
                                ForEach(SceneParticlePreset.allCases, id: \.self) { p in
                                    Text(p.displayName).tag(p)
                                }
                            }

                            if config.particlePreset != .none {
                                HStack {
                                    Text("Density").font(.caption)
                                    Slider(value: $config.particleCount, in: 20...160, step: 5)
                                    Text("\(Int(config.particleCount))").font(.caption2).monospacedDigit().frame(width: 28)
                                }
                                HStack {
                                    Text("Speed").font(.caption)
                                    Slider(value: $config.particleSpeed, in: 0.25...2.5, step: 0.05)
                                    Text(String(format: "%.1fx", config.particleSpeed)).font(.caption2).monospacedDigit().frame(width: 32)
                                }
                                HStack {
                                    Text("Color").font(.caption)
                                    Spacer()
                                    ForEach(["#ffffff", "#00f5d4", "#ff8c42", "#a855f7", "#f43f5e", "#facc15"], id: \.self) { hex in
                                        Button(action: { config.particleColorHex = hex }) {
                                            Circle()
                                                .fill(colorFromHex(hex))
                                                .frame(width: 16, height: 16)
                                                .overlay(
                                                    Circle().stroke(config.particleColorHex == hex ? Color.white : Color.clear, lineWidth: 2)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("Clock & Audio Reactive") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Floating Clock Overlay", isOn: $config.clockEnabled)
                            if config.clockEnabled {
                                Picker("Position", selection: $config.clockPosition) {
                                    ForEach(SceneClockPosition.allCases, id: \.self) { pos in
                                        Text(pos.displayName).tag(pos)
                                    }
                                }
                            }

                            Divider()

                            Toggle("Audio-Reactive Bass Pulse", isOn: $config.audioReactiveEnabled)
                            Toggle("Audio Spectrum Bars", isOn: $config.audioBarsEnabled)
                            if config.audioReactiveEnabled || config.audioBarsEnabled {
                                HStack {
                                    Text("Sensitivity").font(.caption)
                                    Slider(value: $config.audioPulseStrength, in: 0.2...1.5)
                                }
                            }

                            Divider()

                            HStack {
                                Text("Vignette").font(.caption)
                                Slider(value: $config.vignetteIntensity, in: 0...0.85)
                            }
                        }
                        .padding(6)
                    }
                }
                .padding(16)
            }
            .frame(width: 300)
        }
    }

    private func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            config.backgroundImagePath = url.path
            if config.title == "My Custom Scene" {
                config.title = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func saveAndApply() {
        do {
            let item = try SceneExporter.exportScene(config: config)
            store.addCustomWallpaper(item, activate: true)
            exportStatus = "Exported & applied \"\(item.title)\" to Library."
            onSavedAndApplied?(item)
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private func colorFromHex(_ hex: String) -> Color {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}
