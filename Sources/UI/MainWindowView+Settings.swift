import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings & Application Rules section.
extension MainWindowView {
    var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings & Application Rules")
                    .font(.title2)
                    .fontWeight(.bold)

                GroupBox("Performance & Battery") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Pause Wallpaper for Open Windows")
                            Spacer()
                            Picker("", selection: $preferences.windowPauseMode) {
                                ForEach(WindowPauseMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .frame(width: 210)
                        }

                        Toggle("Smooth slow-stop when window opens / pauses", isOn: $preferences.smoothSlowStop)
                        HStack(spacing: 10) {
                            Text("Slow-Stop Duration")
                            Slider(value: $preferences.slowStopDuration, in: 0.5...10.0, step: 0.5)
                                .disabled(!preferences.smoothSlowStop && !preferences.slowStopOnUnlock)
                            Text(String(format: "%.1f s", preferences.slowStopDuration))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 42, alignment: .trailing)
                            Button("Test") {
                                manager.triggerSlowStop(duration: preferences.slowStopDuration)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Toggle("Also slow-stop automatically after unlock", isOn: $preferences.slowStopOnUnlock)

                        Divider()

                        Toggle("Pause on Battery Power", isOn: $preferences.pauseOnBattery)
                        HStack(spacing: 10) {
                            Text("Only When Battery at or Below")
                            Slider(
                                value: Binding(
                                    get: { Double(preferences.pauseOnBatteryBelowPercent) },
                                    set: { preferences.pauseOnBatteryBelowPercent = Int($0) }
                                ),
                                in: 5...100,
                                step: 5
                            )
                            Text(preferences.pauseOnBatteryBelowPercent >= 100 ? "Always" : "\(preferences.pauseOnBatteryBelowPercent)%")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 48, alignment: .trailing)
                        }
                        .disabled(!preferences.pauseOnBattery)
                        if power.isOnBattery, let level = power.batteryLevel {
                            Text("On battery · \(level)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Limit to 30 FPS in macOS Low Power Mode", isOn: $preferences.pauseOnLowPowerMode)
                        Toggle("Manual Battery Override (Resume Anyway)", isOn: $power.overrideSystemPause)

                        HStack {
                            Text("Global FPS Cap")
                            Spacer()
                            Picker("", selection: $preferences.globalFPSCap) {
                                Text("30 FPS").tag(30)
                                Text("60 FPS").tag(60)
                                Text("120 FPS").tag(120)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                    }
                    .padding(8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Per-application overrides evaluated live by PowerMonitor.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: addAppRuleDialog) {
                                Label("Add Application...", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        ForEach(appRules.rules) { rule in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { _ in appRules.toggleRule(id: rule.id) }
                                ))
                                .labelsHidden()

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rule.appName)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text(rule.bundleIdentifier)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Picker("Condition", selection: Binding(
                                    get: { rule.condition },
                                    set: { newCond in
                                        var updated = rule
                                        updated.condition = newCond
                                        appRules.updateRule(updated)
                                    }
                                )) {
                                    ForEach(AppRuleCondition.allCases, id: \.self) { c in
                                        Text(c.displayName).tag(c)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 140)

                                Picker("Action", selection: Binding(
                                    get: { rule.action },
                                    set: { newAct in
                                        var updated = rule
                                        updated.action = newAct
                                        appRules.updateRule(updated)
                                    }
                                )) {
                                    ForEach(AppRuleAction.allCases, id: \.self) { a in
                                        Text(a.displayName).tag(a)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)

                                Button(action: { appRules.removeRule(id: rule.id) }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Application Rules", systemImage: "app.badge.checkmark")
                }

                GroupBox("Audio Visualizer & Sound") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Real-Time Audio Visualizer (ScreenCaptureKit 128-band FFT)", isOn: $preferences.audioVisualizerEnabled)
                            Spacer()
                            Text(audioVisualizer.status.label)
                                .font(.caption)
                                .foregroundColor(audioVisualizer.status == .running ? .green : .secondary)
                        }
                        Toggle("Auto-Mute Wallpaper When Other Apps Play Audio", isOn: $preferences.muteOnExternalAudio)

                        HStack {
                            Text("Wallpaper Audio Volume")
                            Slider(value: $preferences.volume, in: 0...1)
                                .disabled(preferences.isMuted)
                            Text("\(Int(preferences.volume * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 40)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Screensaver Mode") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Enable Wallpaper Screensaver on Idle", isOn: $preferences.screensaverEnabled)
                            Spacer()
                            Button("Start Screensaver Now") {
                                screensaver.startScreensaver()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        HStack {
                            Text("Start after idle")
                            Spacer()
                            Picker("", selection: $preferences.screensaverIdleMinutes) {
                                Text("1 min").tag(1)
                                Text("3 min").tag(3)
                                Text("5 min").tag(5)
                                Text("10 min").tag(10)
                                Text("15 min").tag(15)
                                Text("30 min").tag(30)
                            }
                            .frame(width: 120)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Desktop, Startup, Theme & Hotkeys") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Launch Nimbscape at Login", isOn: $preferences.launchAtLogin)
                        Toggle("Crossfade Transition When Switching Wallpapers", isOn: $preferences.crossfadeTransitions)
                        Toggle("Mouse Parallax Tracking Across Desktop", isOn: $preferences.mouseParallaxTracking)
                        Toggle("Sync Active Wallpaper to macOS Lock Screen & Unlock Transition", isOn: $preferences.syncLockScreenWallpaper)
                        Toggle("Interactive Desktop Mode (Forward mouse clicks to web scenes)", isOn: $preferences.interactiveMode)
                        Toggle("Global Hotkeys (⌘⇧W Switcher · ⌘⇧P Pause · ⌘⇧N Next · ⌘⇧H Hide · ⌘⇧M Mute)", isOn: $preferences.quickSwitcherHotkeyEnabled)

                        HStack {
                            Text("Appearance")
                            Spacer()
                            Picker("", selection: $preferences.appearanceMode) {
                                ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Engine & Storage") {
                    HStack {
                        let hdBytes = StorageJanitor.managedSizeBytes()
                        Text("Downloaded HD Wallpapers: \(ByteCountFormatter.string(fromByteCount: hdBytes, countStyle: .file))")
                            .font(.subheadline)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(HDCatalogDownloader.shared.wallpapersDirectory)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    Text("Removing a downloaded wallpaper from the library also deletes its file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                    HStack {
                        let cacheBytes = FolderCollectionScanner.thumbnailCacheSizeBytes()
                        Text("Thumbnail Cache: \(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))")
                            .font(.subheadline)
                        Spacer()
                        Button("Clear Thumbnail Cache") {
                            FolderCollectionScanner.clearThumbnailCache()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
    }
}
