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
