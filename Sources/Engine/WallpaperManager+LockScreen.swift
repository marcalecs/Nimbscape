import Cocoa
import AVFoundation
import CoreImage
import ImageIO

/// Syncs the active wallpaper to the macOS Lock Screen, Idle and all Spaces (rendered PNG frames
/// with color filters baked in).
extension WallpaperManager {
    nonisolated static var lockScreenSyncDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Nimbscape/LockScreenSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writing a still frame into the system wallpaper would replace the lock-screen video, so
    /// syncing pauses while Nimbscape's video is on the lock screen.
    var shouldSyncSystemWallpaper: Bool {
        AppPreferences.shared.syncLockScreenWallpaper && !LockScreenVideo.shared.isActive
    }

    /// Re-syncs (or stops syncing) after the lock-screen video was installed or removed.
    public func refreshLockScreenSyncAfterLockVideoChange() {
        if shouldSyncSystemWallpaper { syncAllDisplaysToLockScreen() }
    }

    public func syncAllDisplaysToLockScreen() {
        let store = WallpaperStore.shared
        for id in orderedDisplayIDs {
            guard let slot = slotsByDisplayID[id],
                  let wallpaperID = slot.wallpaperID,
                  let item = store.wallpaper(id: wallpaperID) else { continue }
            syncSlotToLockScreen(displayID: id, item: item)
        }
    }

    func syncSlotToLockScreen(displayID: String, item: WallpaperItem) {
        guard let slot = slotsByDisplayID[displayID] else { return }
        let shouldSyncSystem = shouldSyncSystemWallpaper
        let props = item.properties

        switch item.type {
        case .image:
            let imgURL = URL(fileURLWithPath: item.pathOrURL)
            let wallpaperID = item.id
            Task.detached(priority: .utility) {
                guard let savedURL = Self.extractAndSaveImageSyncPNG(url: imgURL, properties: props, key: "\(wallpaperID)_\(displayID)") else { return }
                await MainActor.run { [weak self] in
                    guard let self, let currentSlot = self.slotsByDisplayID[displayID],
                          currentSlot.wallpaperID == wallpaperID else { return }
                    currentSlot.window.setBackdropImage(NSImage(contentsOf: savedURL))
                    if shouldSyncSystem {
                        self.applySystemDesktopWallpaper(fileURL: savedURL, for: currentSlot.screen, alignment: props.alignment)
                    }
                }
            }

        case .video:
            let videoURL = URL(fileURLWithPath: item.pathOrURL)
            let wallpaperID = item.id
            Task.detached(priority: .utility) {
                guard let savedURL = Self.extractAndSaveVideoSyncPNG(url: videoURL, properties: props, key: "\(wallpaperID)_\(displayID)") else { return }
                await MainActor.run { [weak self] in
                    guard let self, let currentSlot = self.slotsByDisplayID[displayID],
                          currentSlot.wallpaperID == wallpaperID else { return }
                    currentSlot.window.setBackdropImage(NSImage(contentsOf: savedURL))
                    if shouldSyncSystem {
                        self.applySystemDesktopWallpaper(fileURL: savedURL, for: currentSlot.screen, alignment: props.alignment)
                    }
                }
            }

        case .web, .url:
            guard let webView = slot.webView else { return }
            let wallpaperID = item.id
            let alignment = props.alignment
            let captureAction: @MainActor () -> Void = { [weak self, weak webView] in
                guard let self, let webView else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    Task { @MainActor [weak self, weak webView] in
                        guard let self, let webView,
                              self.slotsByDisplayID[displayID]?.wallpaperID == wallpaperID else { return }
                        webView.captureSnapshot { [weak self] snapshot in
                            guard let self, let snapshot else { return }
                            self.slotsByDisplayID[displayID]?.window.setBackdropImage(snapshot)
                            guard self.shouldSyncSystemWallpaper,
                                  let tiffData = snapshot.tiffRepresentation else { return }
                            Task.detached(priority: .utility) {
                                if let savedURL = Self.saveSyncPNG(tiffData: tiffData, key: "\(wallpaperID)_\(displayID)") {
                                    await MainActor.run { [weak self] in
                                        if let targetScreen = self?.slotsByDisplayID[displayID]?.screen {
                                            self?.applySystemDesktopWallpaper(fileURL: savedURL, for: targetScreen, alignment: alignment)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            webView.onDidFinishLoad = captureAction
            captureAction()
        }
    }

    func applySystemDesktopWallpaper(fileURL: URL, for screen: NSScreen, alignment: WallpaperAlignment = .fill) {
        let scaling: NSImageScaling
        let allowClipping: Bool
        switch alignment {
        case .fill:
            scaling = .scaleProportionallyUpOrDown
            allowClipping = true
        case .fit:
            scaling = .scaleProportionallyUpOrDown
            allowClipping = false
        case .stretch:
            scaling = .scaleAxesIndependently
            allowClipping = false
        }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: scaling.rawValue,
            .allowClipping: allowClipping
        ]
        try? NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: options)

        syncedLockScreenEntries[screen.stableDisplayID] = (url: fileURL, alignment: alignment)
        scheduleIdleAndSpacesStoreSync()
    }

    func scheduleIdleAndSpacesStoreSync() {
        guard shouldSyncSystemWallpaper else { return }
        idleStoreSyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.shouldSyncSystemWallpaper else { return }
                let entries = self.syncedLockScreenEntries
                guard !entries.isEmpty else { return }
                let primaryID = self.orderedDisplayIDs.first ?? entries.keys.sorted().first ?? ""
                guard let primaryEntry = entries[primaryID] ?? entries.values.first else { return }

                let serializedEntries = entries.mapValues { ($0.url.absoluteString, $0.alignment.rawValue) }
                let primaryPair = (primaryEntry.url.absoluteString, primaryEntry.alignment.rawValue)

                Task.detached(priority: .utility) {
                    let didReload = Self.syncMacOSWallpaperStore(
                        entriesByDisplayID: serializedEntries,
                        primaryEntry: primaryPair
                    )
                    if didReload {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        await MainActor.run { [weak self] in
                            _ = self?.ensureAllWindowsVisible(forceReattach: true)
                        }
                    }
                }
            }
        }
        idleStoreSyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    nonisolated static func syncMacOSWallpaperStore(
        entriesByDisplayID: [String: (String, String)],
        primaryEntry: (String, String)
    ) -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let storeURL = appSupport.appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
        guard let rawData = try? Data(contentsOf: storeURL),
              let parsed = try? PropertyListSerialization.propertyList(from: rawData, options: [], format: nil),
              var root = parsed as? [String: Any] else {
            return false
        }

        let templateDesktop = (root["SystemDefault"] as? [String: Any])?["Desktop"] as? [String: Any]
        let now = Date()
        var didChange = false

        func placementID(for alignmentRaw: String) -> String {
            switch alignmentRaw {
            case WallpaperAlignment.fit.rawValue:
                return "SizeToFit"
            case WallpaperAlignment.stretch.rawValue:
                return "FillScreen"
            default:
                return "Crop"
            }
        }

        func existingImageURL(in slot: [String: Any]?) -> String? {
            guard let content = slot?["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]],
                  let first = choices.first,
                  (first["Provider"] as? String) == "com.apple.wallpaper.choice.image",
                  let cfgData = first["Configuration"] as? Data,
                  let cfgObj = try? PropertyListSerialization.propertyList(from: cfgData, options: [], format: nil) as? [String: Any],
                  let urlDict = cfgObj["url"] as? [String: Any] else {
                return nil
            }
            return urlDict["relative"] as? String
        }

        func makeSlotDict(urlString: String, alignmentRaw: String) -> [String: Any]? {
            let cfgDict: [String: Any] = [
                "type": "imageFile",
                "url": ["relative": urlString]
            ]
            guard let cfgData = try? PropertyListSerialization.data(fromPropertyList: cfgDict, format: .binary, options: 0) else {
                return nil
            }

            var optionsData: Data?
            if let templateContent = templateDesktop?["Content"] as? [String: Any],
               let existingOpts = templateContent["EncodedOptionValues"] as? Data,
               var optsDict = (try? PropertyListSerialization.propertyList(from: existingOpts, options: [], format: nil)) as? [String: Any],
               var values = optsDict["values"] as? [String: Any] {
                values["placement"] = ["picker": ["_0": ["id": placementID(for: alignmentRaw)]]]
                optsDict["values"] = values
                optionsData = try? PropertyListSerialization.data(fromPropertyList: optsDict, format: .binary, options: 0)
            }
            if optionsData == nil {
                let fallbackColorSpace = (try? PropertyListSerialization.data(
                    fromPropertyList: "kCGColorSpaceGenericRGB",
                    format: .binary,
                    options: 0
                )) ?? Data()
                let fallbackOpts: [String: Any] = [
                    "values": [
                        "color": [
                            "color": [
                                "_0": [
                                    "color": [
                                        "colorSpace": fallbackColorSpace,
                                        "components": [0.0, 0.0, 0.0, 1.0]
                                    ]
                                ]
                            ]
                        ],
                        "placement": ["picker": ["_0": ["id": placementID(for: alignmentRaw)]]]
                    ]
                ]
                optionsData = try? PropertyListSerialization.data(fromPropertyList: fallbackOpts, format: .binary, options: 0)
            }

            var content: [String: Any] = [
                "Choices": [[
                    "Configuration": cfgData,
                    "Files": [Any](),
                    "Provider": "com.apple.wallpaper.choice.image"
                ]],
                "Shuffle": "$null"
            ]
            if let optionsData {
                content["EncodedOptionValues"] = optionsData
            }
            return [
                "Content": content,
                "LastSet": now,
                "LastUse": now
            ]
        }

        func patchConfigNode(_ node: [String: Any], entry: (String, String), idleOnlyWhenLinked: Bool = false) -> [String: Any] {
            var updated = node
            let (urlString, alignmentRaw) = entry
            guard let slotDict = makeSlotDict(urlString: urlString, alignmentRaw: alignmentRaw) else {
                return updated
            }

            if (updated["Type"] as? String) == "linked" || updated["Linked"] != nil {
                updated.removeValue(forKey: "Linked")
                if idleOnlyWhenLinked {
                    updated["Type"] = "idle"
                    updated.removeValue(forKey: "Desktop")
                    updated["Idle"] = slotDict
                } else {
                    updated["Type"] = "individual"
                    updated["Desktop"] = slotDict
                    updated["Idle"] = slotDict
                }
                didChange = true
                return updated
            }

            if updated["Desktop"] != nil {
                if existingImageURL(in: updated["Desktop"] as? [String: Any]) != urlString {
                    updated["Desktop"] = slotDict
                    didChange = true
                }
            }
            if updated["Idle"] != nil {
                if existingImageURL(in: updated["Idle"] as? [String: Any]) != urlString {
                    updated["Idle"] = slotDict
                    didChange = true
                }
            }
            return updated
        }

        if let allNode = root["AllSpacesAndDisplays"] as? [String: Any] {
            root["AllSpacesAndDisplays"] = patchConfigNode(allNode, entry: primaryEntry, idleOnlyWhenLinked: true)
        }
        if let sysNode = root["SystemDefault"] as? [String: Any] {
            root["SystemDefault"] = patchConfigNode(sysNode, entry: primaryEntry)
        }
        if var displaysDict = root["Displays"] as? [String: Any] {
            for (dispID, rawVal) in displaysDict {
                if let dispNode = rawVal as? [String: Any] {
                    let entry = entriesByDisplayID[dispID] ?? primaryEntry
                    displaysDict[dispID] = patchConfigNode(dispNode, entry: entry)
                }
            }
            root["Displays"] = displaysDict
        }
        if var spacesDict = root["Spaces"] as? [String: Any] {
            for (spaceID, rawSpace) in spacesDict {
                guard var spaceNode = rawSpace as? [String: Any] else { continue }
                if let defNode = spaceNode["Default"] as? [String: Any] {
                    spaceNode["Default"] = patchConfigNode(defNode, entry: primaryEntry)
                }
                if var spaceDisplays = spaceNode["Displays"] as? [String: Any] {
                    for (dispID, rawDisp) in spaceDisplays {
                        if let dispNode = rawDisp as? [String: Any] {
                            let entry = entriesByDisplayID[dispID] ?? primaryEntry
                            spaceDisplays[dispID] = patchConfigNode(dispNode, entry: entry)
                        }
                    }
                    spaceNode["Displays"] = spaceDisplays
                }
                spacesDict[spaceID] = spaceNode
            }
            root["Spaces"] = spacesDict
        }

        guard didChange,
              let outData = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) else {
            return false
        }

        do {
            try outData.write(to: storeURL, options: .atomic)
        } catch {
            return false
        }

        let activeFileNames = Set(
            ([primaryEntry.0] + entriesByDisplayID.values.map { $0.0 })
                .compactMap { URL(string: $0)?.lastPathComponent }
        )
        if !activeFileNames.isEmpty,
           let files = try? FileManager.default.contentsOfDirectory(at: lockScreenSyncDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "png" && !activeFileNames.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["WallpaperAgent"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return true
    }

    nonisolated static func applyColorFilters(to cgImage: CGImage, properties: WallpaperProperties) -> CGImage {
        guard properties.hasColorAdjustments else { return cgImage }

        var ciImage = CIImage(cgImage: cgImage)
        if abs(properties.hue) > 0.01, let hueFilter = CIFilter(name: "CIHueAdjust") {
            hueFilter.setValue(ciImage, forKey: kCIInputImageKey)
            hueFilter.setValue(properties.hue * .pi / 180.0, forKey: kCIInputAngleKey)
            if let out = hueFilter.outputImage {
                ciImage = out
            }
        }

        if abs(properties.brightness - 1.0) > 0.01
            || abs(properties.contrast - 1.0) > 0.01
            || abs(properties.saturation - 1.0) > 0.01,
           let colorControls = CIFilter(name: "CIColorControls") {
            let mappedBrightness = max(-0.5, min(0.5, (properties.brightness - 1.0) * 0.5))
            colorControls.setValue(ciImage, forKey: kCIInputImageKey)
            colorControls.setValue(mappedBrightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(properties.contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(properties.saturation, forKey: kCIInputSaturationKey)
            if let out = colorControls.outputImage {
                ciImage = out
            }
        }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(ciImage, from: ciImage.extent) ?? cgImage
    }

    nonisolated static func extractAndSaveImageSyncPNG(
        url: URL,
        properties: WallpaperProperties,
        key: String
    ) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let idx = count > 2 ? count / 2 : 0
        guard let rawCG = CGImageSourceCreateImageAtIndex(source, idx, nil) else { return nil }
        let styledCG = applyColorFilters(to: rawCG, properties: properties)
        let rep = NSBitmapImageRep(cgImage: styledCG)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        return writeSyncPNGData(pngData, key: key)
    }

    nonisolated static func extractAndSaveVideoSyncPNG(
        url: URL,
        properties: WallpaperProperties,
        key: String
    ) -> URL? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 2560, height: 1440)
        for sec in [1.0, 0.0] {
            if let rawCG = try? gen.copyCGImage(at: CMTime(seconds: sec, preferredTimescale: 600), actualTime: nil) {
                let styledCG = applyColorFilters(to: rawCG, properties: properties)
                let rep = NSBitmapImageRep(cgImage: styledCG)
                if let pngData = rep.representation(using: .png, properties: [:]) {
                    return writeSyncPNGData(pngData, key: key)
                }
            }
        }
        return nil
    }

    nonisolated static func saveSyncPNG(tiffData: Data, key: String) -> URL? {
        guard let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return writeSyncPNGData(pngData, key: key)
    }

    nonisolated static func writeSyncPNGData(_ pngData: Data, key: String) -> URL? {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let dir = lockScreenSyncDir
        let dest = dir.appendingPathComponent("\(safeKey)_\(stamp).png")

        do {
            try pngData.write(to: dest, options: .atomic)
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in files where f.lastPathComponent != dest.lastPathComponent && f.lastPathComponent.hasPrefix("\(safeKey)_") {
                    try? FileManager.default.removeItem(at: f)
                }
            }
            return dest
        } catch {
            return nil
        }
    }
}
