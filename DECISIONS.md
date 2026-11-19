# Architecture & Engineering Decisions

## Desktop Layering & Window Management
- Desktop windows are positioned at `CGWindowLevelForKey(.desktopIconWindow) - 1`, placing live wallpapers above Dock desktop surfaces and strictly below Finder desktop icons and widgets.
- `WallpaperWindow` enables `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle`, and `.fullScreenAuxiliary` with `canHide = false`, `hidesOnDeactivate = false`, and `isReleasedWhenClosed = false`.
- Visibility recovery relies on native macOS window hierarchy (`isVisible && isOnActiveSpace`) rather than WindowServer compositing queries (`kCGWindowIsOnscreen`), preventing false-positive reattachment loops when foreground windows obscure the desktop icon level. Debounces Space-change handling by `0.45s` to avoid interfering with trackpad gestures.

## Rendering & Energy Efficiency
- Built-in HTML5 presets use offscreen cached backgrounds, pre-rendered gradients, and zero per-frame `shadowBlur` or animated CSS blur filters.
- `WebWallpaperView` uses `setTimeout`-aligned frame scheduling below 55 FPS and halts callbacks when paused.
- `VideoWallpaperView` and `ImageWallpaperView` enable `layerUsesCoreImageFilters` only when color adjustments are non-neutral, allowing zero-copy hardware video scanout by default.
- Animated GIFs decode natively via `ImageIO` and `CAKeyframeAnimation` without WebKit overhead.
- *(2026-11-19)* Window occlusion polling interval relaxed to `2.5s` (with `1.0s` tolerance) and battery telemetry to `15s` to maximize Apple Silicon low-power core sleep states. Visibility watchdog respects active pause state (`guard !effectiveIsPaused`) to eliminate infinite unpause loops. Battery and Low Power Mode auto-pauses enabled by default.
- *(2026-11-19)* Swift 6 Concurrency: All `NSWorkspace` and `NotificationCenter` power/display observers route asynchronously into `@MainActor` tasks via block-based APIs to eliminate cross-thread `SIGTRAP` / `_dispatch_assert_queue_fail` aborts.

## Lock Screen & Smooth Deceleration
- Active wallpapers sync to the macOS Lock Screen via `NSWorkspace.setDesktopImageURL`, baking CoreImage color/tone filters (`CIHueAdjust`, `CIColorControls`) and alignment into the exported PNG and re-syncing after live property edits.
- Window-occlusion and manual pauses support smooth ease-out deceleration (`speed = baseSpeed * (1 - t)^2`) over a configurable duration.

## Feature Architecture
- **Playlists & Schedules**: Interval, Time-of-Day, On-Unlock, and Manual modes with shuffle and crossfade transitions.
- **Audio Visualizer**: `ScreenCaptureKit` system audio loopback with `Accelerate/vDSP` 128-band stereo FFT driving `window.nimbscapeRegisterAudioListener`.
- **2D Scene Editor**: Live `WKWebView` preview composer exporting standalone `index.html` + `project.json` scenes.
- **Discover & Local Collections**: Native Full HD/4K MP4 catalog downloaded via background `URLSessionDownloadTask`, `.webm` HTML5 wrapper, and local folder collection scanner.
- **System Integration**: `SMAppService.mainApp` launch at login, multi-monitor `ProfileStore`, idle `ScreensaverEngine`, and global Carbon hotkeys (`⌘⇧W`, `⌘⇧P`, `⌘⇧N`, `⌘⇧H`, `⌘⇧M`).
