import SwiftUI

public struct PlaylistsView: View {
    @ObservedObject var playlistStore = PlaylistStore.shared
    @ObservedObject var wallpaperStore = WallpaperStore.shared

    @State private var selectedPlaylistID: String? = PlaylistStore.shared.playlists.first?.id
    @State private var newPlaylistName: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playlists & Schedules")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(activeStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { playlistStore.advanceNext() }) {
                    Label("Next Wallpaper (⌘⇧N)", systemImage: "forward.end.fill")
                }
                .buttonStyle(.bordered)

                if playlistStore.activePlaylistID != nil {
                    Button("Stop Playlist") {
                        playlistStore.activePlaylistID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .padding(20)

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        TextField("New playlist name...", text: $newPlaylistName)
                            .textFieldStyle(.roundedBorder)
                        Button(action: {
                            let created = playlistStore.createPlaylist(name: newPlaylistName)
                            newPlaylistName = ""
                            selectedPlaylistID = created.id
                        }) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding([.horizontal, .top], 14)

                    List(playlistStore.playlists, selection: $selectedPlaylistID) { playlist in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(playlist.name)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    if playlistStore.activePlaylistID == playlist.id {
                                        Text("ACTIVE")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.green)
                                            .foregroundColor(.white)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(playlist.rotationMode.displayName) · \(playlist.wallpaperIDs.count) items")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .tag(playlist.id)
                    }
                    .listStyle(.inset)
                }
                .frame(width: 220)

                Divider()

                if let pid = selectedPlaylistID,
                   let idx = playlistStore.playlists.firstIndex(where: { $0.id == pid }) {
                    let binding = $playlistStore.playlists[idx]
                    let isActive = (playlistStore.activePlaylistID == pid)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                TextField("Playlist Name", text: binding.name)
                                    .font(.title3)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 280)

                                Spacer()

                                Button(isActive ? "Deactivate" : "Activate Playlist") {
                                    playlistStore.activePlaylistID = isActive ? nil : pid
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(isActive ? .orange : .green)

                                Button(action: {
                                    playlistStore.deletePlaylist(id: pid)
                                    selectedPlaylistID = playlistStore.playlists.first?.id
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.bordered)
                            }

                            GroupBox("Rotation Schedule") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Picker("Rotation Mode", selection: binding.rotationMode) {
                                        ForEach(PlaylistRotationMode.allCases, id: \.self) { mode in
                                            Text(mode.displayName).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)

                                    if binding.wrappedValue.rotationMode == .interval {
                                        HStack {
                                            Text("Change wallpaper every")
                                            Picker("", selection: binding.intervalMinutes) {
                                                Text("1 min").tag(1)
                                                Text("5 min").tag(5)
                                                Text("15 min").tag(15)
                                                Text("30 min").tag(30)
                                                Text("1 hour").tag(60)
                                                Text("2 hours").tag(120)
                                            }
                                            .frame(width: 120)
                                            Spacer()
                                            Toggle("Shuffle Order", isOn: binding.shuffle)
                                        }
                                    } else if binding.wrappedValue.rotationMode == .onUnlock || binding.wrappedValue.rotationMode == .manualOnly {
                                        Toggle("Shuffle Order", isOn: binding.shuffle)
                                    } else if binding.wrappedValue.rotationMode == .timeOfDay {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(TimeOfDaySlot.allCases, id: \.self) { slot in
                                                HStack {
                                                    Text(slot.displayName)
                                                        .frame(width: 180, alignment: .leading)
                                                    Picker("", selection: Binding(
                                                        get: { binding.wrappedValue.timeOfDaySlots[slot.rawValue] ?? wallpaperStore.activeWallpaperId },
                                                        set: { newVal in
                                                            binding.wrappedValue.timeOfDaySlots[slot.rawValue] = newVal
                                                        }
                                                    )) {
                                                        ForEach(wallpaperStore.wallpapers) { wp in
                                                            Text(wp.title).tag(wp.id)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(8)
                            }

                            if binding.wrappedValue.rotationMode != .timeOfDay {
                                GroupBox("Wallpapers in Playlist (\(binding.wrappedValue.wallpaperIDs.count))") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(wallpaperStore.wallpapers) { wp in
                                            let included = binding.wrappedValue.wallpaperIDs.contains(wp.id)
                                            Toggle(isOn: Binding(
                                                get: { included },
                                                set: { _ in
                                                    playlistStore.toggleWallpaper(wp.id, inPlaylist: pid)
                                                }
                                            )) {
                                                HStack {
                                                    Text(wp.title)
                                                    Spacer()
                                                    Text(wp.type.rawValue.uppercased())
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                    }
                                    .padding(8)
                                }
                            }
                        }
                        .padding(20)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("Select or create a playlist to schedule wallpaper rotation.")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var activeStatusText: String {
        if let active = playlistStore.activePlaylist {
            return "Active Playlist: \(active.name) (\(active.rotationMode.displayName))"
        }
        return "Single Wallpaper Mode (no active playlist)"
    }
}
