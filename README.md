# Nimbscape

Native macOS live wallpaper app written in strict Swift 6 with zero third-party dependencies.

## Features

- **Native Desktop Layering**: Renders live video (`.mp4`, `.mov`, `.m4v`, `.webm`), HTML5/Canvas/WebGL scenes, animated GIFs (`ImageIO`), and images cleanly below desktop icons and widgets.
- **Built-In Minimalist Presets**: *Misty Alpine Dawn*, *Nordic Aurora*, *Rainy Glass Dusk*, *Silk Ink Waves*, *Minimal Glass Clock*, and *Ambient Sound Horizon*.
- **Playlists & Schedules**: Interval rotation, Time-of-Day slots, On-Unlock rotation, Shuffle, and smooth Crossfade transitions.
- **Real-Time Audio Visualizer**: System audio loopback via `ScreenCaptureKit` + 128-band stereo FFT (`Accelerate/vDSP`) feeding the `window.nimbscapeRegisterAudioListener` JS API.
- **2D Scene Editor**: Live composer with mouse parallax, breathing motion, water ripples, weather/ambient particles, clock overlay, and standalone HTML5 scene export.
- **Discover & Local Collections**: Built-in Full HD / 4K live wallpaper catalog plus a local folder collection scanner for video, HTML5, and image packages.
- **Multi-Monitor & Profiles**: Independent `Per Display`, synchronized `Clone`, and spanned `Stretch` modes with saved display profiles.
- **Smart Power & Lock Screen Sync**: Auto-pause on open/maximized/fullscreen windows with smooth ease-out deceleration, per-app rules, optional battery/Low Power Mode pause, idle screensaver, and automatic Lock Screen sync with live CoreImage color/tone filters.

## Global Hotkeys

| Shortcut | Action |
| --- | --- |
| `⌘⇧W` | Open Quick Switcher |
| `⌘⇧P` | Play / Pause Wallpapers |
| `⌘⇧N` | Next Wallpaper |
| `⌘⇧H` | Hide / Show Wallpapers |
| `⌘⇧M` | Mute / Unmute Audio |

## Requirements

- macOS 14.0 or later (Apple Silicon & Intel)
- Xcode Command Line Tools (`xcode-select --install`)

## Installation via `build.sh`

```bash
git clone https://github.com/marcalecs/Nimbscape.git
cd Nimbscape
chmod +x build.sh
./build.sh
```

After the build completes, launch the app or move it to `/Applications`:

```bash
open Nimbscape.app
```

To install permanently into Applications:

```bash
cp -R Nimbscape.app /Applications/
open /Applications/Nimbscape.app
```

Alternatively, you can download a prebuilt archive from the [Releases](https://github.com/marcalecs/Nimbscape/releases) page.

> **Note**: Enabling the optional real-time Audio Visualizer requests macOS *Screen & System Audio Recording* permission for `Nimbscape`.

## Author & Contact

- Telegram: [@marcalecs](https://t.me/marcalecs)

## License

MIT License — see [LICENSE](LICENSE).
