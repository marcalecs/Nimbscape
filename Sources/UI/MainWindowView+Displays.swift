import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Displays & Profiles section.
extension MainWindowView {
    var displaysView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose Display & Multi-Monitor Mode")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure how single looping wallpapers map across your connected displays.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { manager.identifyDisplays() }) {
                    Label("Identify Displays", systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 12) {
                ForEach(DisplayLayoutMode.allCases, id: \.self) { mode in
                    let selected = store.displayLayoutMode == mode
                    Button(action: { store.displayLayoutMode = mode }) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: mode.symbolName)
                                    .font(.title3)
                                    .foregroundColor(selected ? .accentColor : .secondary)
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            Text(mode.displayName)
                                .font(.headline)
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Text("Connected Displays (\(manager.connectedDisplays.count))")
                .font(.headline)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(manager.connectedDisplays) { display in
                        let assigned = store.wallpaper(forStableDisplayID: display.id)
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.16))
                                    .frame(width: 64, height: 42)
                                Text("\(display.index)")
                                    .font(.title2)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Display \(display.index) — \(display.name)")
                                        .font(.headline)
                                    if display.isMain {
                                        Text("MAIN")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(display.resolutionText) (Logical \(display.logicalResolutionText))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if store.displayLayoutMode == .perDisplay {
                                Picker("Wallpaper", selection: Binding(
                                    get: { assigned?.id ?? store.activeWallpaperId },
                                    set: { newID in
                                        store.setActiveWallpaper(newID, forStableDisplayID: display.id)
                                    }
                                )) {
                                    ForEach(store.wallpapers) { wp in
                                        Text(wp.title).tag(wp.id)
                                    }
                                }
                                .frame(width: 230)
                            } else {
                                Text(assigned?.title ?? "—")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(14)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(12)
                    }

                    Divider()
                        .padding(.vertical, 6)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Saved Display Profiles")
                                .font(.headline)
                            Spacer()
                            TextField("Profile name...", text: $newProfileName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                            Button("Save Current Setup") {
                                profiles.saveCurrentAsProfile(name: newProfileName)
                                newProfileName = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        if profiles.profiles.isEmpty {
                            Text("No saved profiles yet. Save your current displays & layout to switch in 1 click.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(profiles.profiles) { prof in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(prof.name)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Text("\(prof.layoutMode.displayName) · \(prof.displayAssignments.count) display mapping(s)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button("Apply") {
                                        profiles.applyProfile(prof)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    Button(action: { profiles.deleteProfile(id: prof.id) }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.05))
                                .cornerRadius(10)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
    }

}
