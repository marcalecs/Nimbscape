import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Create section and import actions.
extension MainWindowView {
    var createView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Create / Import Dynamic Wallpaper")
                .font(.title2)
                .fontWeight(.bold)

            if let err = importErrorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                    Text(err)
                        .font(.subheadline)
                    Spacer()
                    Button("Dismiss") { importErrorMessage = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(12)
                .background(Color.red.opacity(0.14))
                .cornerRadius(10)
            }

            HStack(spacing: 16) {
                createTile(title: "Video File", subtitle: "MP4, MOV, M4V, WebM", icon: "video.badge.plus", color: .blue) {
                    importVideo()
                }
                createTile(title: "Wallpaper Folder", subtitle: "project.json or HTML5", icon: "folder.badge.gearshape", color: .purple) {
                    importFolder()
                }
                createTile(title: "Image / Animated GIF", subtitle: "GIF, PNG, JPG, HEIC, WebP", icon: "photo.badge.plus", color: .green) {
                    importImage()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Add Interactive Web / WebGL URL")
                    .font(.headline)
                HStack(spacing: 10) {
                    TextField("Title", text: $urlTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    TextField("https://...", text: $urlInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Add & Apply") {
                        guard !urlInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let title = urlTitle.isEmpty ? "Web Scene" : urlTitle
                        let item = WallpaperItem(title: title, type: .url, pathOrURL: urlInput, source: .webURL)
                        store.addCustomWallpaper(item, activate: true)
                        urlTitle = ""
                        urlInput = ""
                        selectedWallpaperID = item.id
                        selectedSection = .installed
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Spacer()
        }
        .padding(24)
    }

    func createTile(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    func importVideo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK, let url = panel.url {
            importErrorMessage = nil
            let item = WallpaperPackageParser.parseVideoFile(at: url)
            store.addCustomWallpaper(item, activate: true)
            FolderCollectionScanner.generateThumbnailAsync(for: item)
            selectedWallpaperID = item.id
            selectedSection = .installed
        }
    }

    func importImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .gif]
        if panel.runModal() == .OK, let url = panel.url {
            importErrorMessage = nil
            let item = WallpaperPackageParser.parseImageFile(at: url)
            store.addCustomWallpaper(item, activate: true)
            selectedWallpaperID = item.id
            selectedSection = .installed
        }
    }

    func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            switch WallpaperPackageParser.parseFolderResult(at: url, source: .localImport) {
            case .success(let item):
                importErrorMessage = nil
                store.addCustomWallpaper(item, activate: true)
                FolderCollectionScanner.generateThumbnailAsync(for: item)
                selectedWallpaperID = item.id
                selectedSection = .installed
            case .failure(let error):
                importErrorMessage = error.localizedDescription
            }
        }
    }

    func chooseCollectionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select a local folder containing wallpaper packages"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.collectionFolderPath = url.path
            scanner.scan(directoryURL: url)
        }
    }

    func addAppRuleDialog() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url,
           let rule = AppRulesStore.makeRule(fromAppURL: url) {
            appRules.addRule(rule)
        }
    }
}
