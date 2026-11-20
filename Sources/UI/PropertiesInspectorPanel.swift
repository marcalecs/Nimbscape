import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct PropertiesInspectorPanel: View {
    @ObservedObject var store = WallpaperStore.shared
    let wallpaperID: String

    private var item: WallpaperItem? {
        store.wallpaper(id: wallpaperID)
    }

    private func propsBinding<T>(_ keyPath: WritableKeyPath<WallpaperProperties, T>) -> Binding<T> {
        Binding(
            get: {
                store.wallpaper(id: wallpaperID)?.properties[keyPath: keyPath] ?? WallpaperProperties()[keyPath: keyPath]
            },
            set: { newValue in
                guard var props = store.wallpaper(id: wallpaperID)?.properties else { return }
                props[keyPath: keyPath] = newValue
                store.updateProperties(props, for: wallpaperID)
            }
        )
    }

    public var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(item.resolutionLabel ?? item.type.rawValue.uppercased())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: { store.toggleFavorite(id: item.id) }) {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                .foregroundColor(item.isFavorite ? .pink : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: { store.setActiveWallpaper(item.id) }) {
                        Label(
                            item.id == store.activeWallpaperId ? "Currently Active" : "Apply Wallpaper",
                            systemImage: "checkmark.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(item.id == store.activeWallpaperId ? .green : .accentColor)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("PLAYBACK & ALIGNMENT")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("Speed")
                            Spacer()
                            Text(String(format: "%.2fx", item.properties.speed))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: propsBinding(\.speed), in: 0.25...2.0, step: 0.05)

                        HStack {
                            Text("FPS Cap")
                            Spacer()
                            Picker("", selection: propsBinding(\.fpsCap)) {
                                Text("30").tag(30)
                                Text("60").tag(60)
                                Text("120").tag(120)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 150)
                        }

                        HStack {
                            Text("Alignment")
                            Spacer()
                            Picker("", selection: propsBinding(\.alignment)) {
                                ForEach(WallpaperAlignment.allCases, id: \.self) { a in
                                    Text(a.displayName).tag(a)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("COLOR & TONE (LIVE)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)

                        filterSlider(label: "Hue", value: propsBinding(\.hue), range: -180...180, format: "%.0f°")
                        filterSlider(label: "Brightness", value: propsBinding(\.brightness), range: 0.5...1.5, format: "%.2f")
                        filterSlider(label: "Contrast", value: propsBinding(\.contrast), range: 0.5...1.6, format: "%.2f")
                        filterSlider(label: "Saturation", value: propsBinding(\.saturation), range: 0.0...2.0, format: "%.2f")
                    }

                    if !item.projectPropertySpecs.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SCENE PROPERTIES (project.json)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)

                            ForEach(item.projectPropertySpecs) { spec in
                                projectPropertyControl(spec: spec)
                            }
                        }
                    }

                    Divider()

                    Button("Reset Properties to Default") {
                        store.resetProperties(for: item.id)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    if item.type == .video {
                        Divider()
                        LockScreenVideoSection(item: item)
                    }
                }
                .padding(16)
            } else {
                Text("Select a wallpaper to inspect its live properties.")
                    .foregroundColor(.secondary)
                    .padding(20)
            }
        }
    }

    private func filterSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    @ViewBuilder
    private func projectPropertyControl(spec: ProjectPropertySpec) -> some View {
        let stringBinding = Binding<String>(
            get: {
                store.wallpaper(id: wallpaperID)?.properties.customProps[spec.key] ?? spec.defaultValue
            },
            set: { newVal in
                guard var props = store.wallpaper(id: wallpaperID)?.properties else { return }
                props.customProps[spec.key] = newVal
                store.updateProperties(props, for: wallpaperID)
            }
        )

        switch spec.type {
        case .bool:
            Toggle(spec.text, isOn: Binding(
                get: { stringBinding.wrappedValue.lowercased() == "true" || stringBinding.wrappedValue == "1" },
                set: { stringBinding.wrappedValue = $0 ? "true" : "false" }
            ))
        case .slider:
            let minVal = spec.min ?? 0
            let maxVal = spec.max ?? 100
            let numBinding = Binding<Double>(
                get: { Double(stringBinding.wrappedValue) ?? minVal },
                set: { stringBinding.wrappedValue = String(format: "%.2f", $0) }
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(spec.text).font(.subheadline)
                    Spacer()
                    Text(stringBinding.wrappedValue)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: numBinding, in: minVal...max(minVal + 0.01, maxVal))
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.text).font(.caption).foregroundColor(.secondary)
                TextField(spec.key, text: stringBinding)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

/// "Lock Screen" controls for a video wallpaper (macOS 26+): plays it on the lock screen by
/// replacing the video of the Aerial chosen in System Settings.
struct LockScreenVideoSection: View {
    let item: WallpaperItem
    @ObservedObject private var lockVideo = LockScreenVideo.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LOCK SCREEN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("EXPERIMENTAL").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }

            Picker("Play for", selection: $lockVideo.playDuration) {
                ForEach(LockScreenTimeline.PlayDuration.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            switch lockVideo.state {
            case .encoding(let progress):
                HStack {
                    ProgressView(value: progress).controlSize(.small)
                    Text("\(Int(progress * 100))%").font(.caption.monospacedDigit())
                    Button("Cancel") { lockVideo.cancel() }.controlSize(.small)
                }
                Text("Preparing the video for the lock screen…").font(.caption).foregroundStyle(.secondary)
            default:
                Button {
                    lockVideo.install(item)
                } label: {
                    Label(isCurrent ? "Update Lock Screen Video" : "Set as Lock Screen", systemImage: "lock.display")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if case .failed(let message) = lockVideo.state {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if LockScreenVideo.selectedAerialAssetID() == nil {
                    Button("Open Wallpaper Settings") { LockScreenVideo.openWallpaperSettings() }.controlSize(.small)
                }
            }

            if let installed = lockVideo.installed {
                if lockVideo.wasRestoredByMacOS {
                    Text("macOS restored its own Aerial video. Set it again to bring \(installed.title) back.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("On the lock screen: \(installed.title)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Restore Apple's Aerial") { lockVideo.restore() }.controlSize(.small)
            } else {
                Text("Uses the Aerial picked in System Settings → Wallpaper (any downloadable one, not Tahoe Day). macOS shows its clock and password field over the video.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isCurrent: Bool { lockVideo.installed?.wallpaperID == item.id && lockVideo.isActive }
}
