import Foundation

public enum SceneParticlePreset: String, Codable, CaseIterable, Sendable {
    case none
    case snow
    case rain
    case embers
    case stars
    case fireflies

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .snow: return "Snow"
        case .rain: return "Neon Rain"
        case .embers: return "Fire Embers"
        case .stars: return "Starfield"
        case .fireflies: return "Fireflies"
        }
    }
}

public enum SceneClockPosition: String, Codable, CaseIterable, Sendable {
    case center
    case topLeft
    case topRight
    case bottomLeft

    public var displayName: String {
        switch self {
        case .center: return "Center"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        }
    }
}

public struct SceneProjectConfig: Codable, Equatable, Sendable {
    public var title: String = "My Custom Scene"
    public var backgroundImagePath: String? = nil
    public var backgroundColorHex: String = "#090b16"

    public var parallaxEnabled: Bool = true
    public var parallaxStrength: Double = 20.0

    public var breathingEnabled: Bool = true
    public var breathingStrength: Double = 0.03

    public var rippleEnabled: Bool = false
    public var rippleIntensity: Double = 0.4

    public var particlePreset: SceneParticlePreset = .embers
    public var particleCount: Double = 70
    public var particleSpeed: Double = 1.0
    public var particleColorHex: String = "#ff8c42"

    public var clockEnabled: Bool = true
    public var clockPosition: SceneClockPosition = .center

    public var audioReactiveEnabled: Bool = true
    public var audioBarsEnabled: Bool = false
    public var audioPulseStrength: Double = 0.6

    public var vignetteIntensity: Double = 0.45

    public init() {}
}

public enum SceneExporter {
    public static var customScenesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Nimbscape/CustomScenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func generateHTML(config: SceneProjectConfig, imageRelativeSrc: String?) -> String {
        let escapedTitle = config.title.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let bgImgJS = imageRelativeSrc.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" } ?? "null"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>\(escapedTitle)</title>
          <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { width: 100%; height: 100%; overflow: hidden; background: \(config.backgroundColorHex); font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; }
            canvas { display: block; width: 100%; height: 100%; }
          </style>
        </head>
        <body>
          <canvas id="c"></canvas>
          <script>
            const CFG = {
              bgColor: '\(config.backgroundColorHex)',
              bgImage: \(bgImgJS),
              parallax: \(config.parallaxEnabled ? "true" : "false"),
              parallaxStrength: \(config.parallaxStrength),
              breathing: \(config.breathingEnabled ? "true" : "false"),
              breathingStrength: \(config.breathingStrength),
              ripple: \(config.rippleEnabled ? "true" : "false"),
              rippleIntensity: \(config.rippleIntensity),
              particles: '\(config.particlePreset.rawValue)',
              particleCount: \(Int(config.particleCount)),
              particleSpeed: \(config.particleSpeed),
              particleColor: '\(config.particleColorHex)',
              clock: \(config.clockEnabled ? "true" : "false"),
              clockPos: '\(config.clockPosition.rawValue)',
              audioReactive: \(config.audioReactiveEnabled ? "true" : "false"),
              audioBars: \(config.audioBarsEnabled ? "true" : "false"),
              audioPulse: \(config.audioPulseStrength),
              vignette: \(config.vignetteIntensity)
            };

            window.wallpaperPropertyListener = {
              applyUserProperties: function(props) {
                if (props.particlespeed) CFG.particleSpeed = Number(props.particlespeed.value) || CFG.particleSpeed;
                if (props.parallaxstrength) CFG.parallaxStrength = Number(props.parallaxstrength.value) || CFG.parallaxStrength;
                if (props.showclock) CFG.clock = !!props.showclock.value;
                if (props.audiobars) CFG.audioBars = !!props.audiobars.value;
              }
            };

            const canvas = document.getElementById('c');
            const ctx = canvas.getContext('2d', { alpha: false });
            let width = 1, height = 1;
            let mouseX = 0, mouseY = 0, smoothMX = 0, smoothMY = 0;

            window.addEventListener('mousemove', e => {
              mouseX = (e.clientX / Math.max(1, window.innerWidth) - 0.5) * 2;
              mouseY = (e.clientY / Math.max(1, window.innerHeight) - 0.5) * 2;
            });
            window.addEventListener('ns-mousemove', e => {
              if (e.detail) { mouseX = e.detail.x; mouseY = e.detail.y; }
            });

            let audioBass = 0;
            const audioSpectrum = new Float32Array(64);
            if (typeof window.wallpaperRegisterAudioListener === 'function') {
              window.wallpaperRegisterAudioListener(arr => {
                if (!arr || arr.length < 64) return;
                let bass = 0;
                for (let i = 0; i < 64; i++) {
                  const v = Math.min(1, ((Number(arr[i]) || 0) + (Number(arr[i + 64]) || 0)) * 0.6);
                  audioSpectrum[i] += (v - audioSpectrum[i]) * 0.3;
                  if (i < 8) bass += audioSpectrum[i];
                }
                audioBass = bass / 8;
              });
            }

            let bgImg = null;
            if (CFG.bgImage) {
              const img = new Image();
              img.onload = () => { bgImg = img; };
              img.src = CFG.bgImage;
            }

            const parts = [];
            function initParticles() {
              parts.length = 0;
              const n = CFG.particles === 'none' ? 0 : CFG.particleCount;
              for (let i = 0; i < n; i++) {
                parts.push({
                  x: Math.random() * width,
                  y: Math.random() * height,
                  r: Math.random() * 2.6 + 1.0,
                  vx: (Math.random() - 0.5) * 0.8,
                  vy: Math.random() * 1.4 + 0.5,
                  a: Math.random() * 0.7 + 0.2,
                  p: Math.random() * Math.PI * 2
                });
              }
            }

            function resize() {
              width = canvas.width = Math.max(1, window.innerWidth);
              height = canvas.height = Math.max(1, window.innerHeight);
              initParticles();
            }
            window.addEventListener('resize', resize);
            resize();

            let t = 0;
            function draw() {
              const spd = window.__nsSpeed ?? 1.0;
              t += 0.016 * spd;
              smoothMX += (mouseX - smoothMX) * 0.08;
              smoothMY += (mouseY - smoothMY) * 0.08;

              ctx.fillStyle = CFG.bgColor;
              ctx.fillRect(0, 0, width, height);

              const bassBoost = CFG.audioReactive ? (audioBass * CFG.audioPulse * 0.06) : 0;
              const breathScale = CFG.breathing ? (1 + Math.sin(t * 1.1) * CFG.breathingStrength) : 1.0;
              const padScale = (CFG.parallax ? 1.06 : 1.0) * breathScale + bassBoost;
              const ox = CFG.parallax ? (-smoothMX * CFG.parallaxStrength) : 0;
              const oy = CFG.parallax ? (-smoothMY * CFG.parallaxStrength) : 0;

              if (bgImg && bgImg.naturalWidth > 0) {
                const imgRatio = bgImg.naturalWidth / bgImg.naturalHeight;
                const winRatio = width / height;
                let dw, dh;
                if (imgRatio > winRatio) {
                  dh = height * padScale;
                  dw = dh * imgRatio;
                } else {
                  dw = width * padScale;
                  dh = dw / imgRatio;
                }
                const dx = (width - dw) * 0.5 + ox;
                const dy = (height - dh) * 0.5 + oy;
                ctx.drawImage(bgImg, dx, dy, dw, dh);
              } else {
                const g = ctx.createRadialGradient(width * 0.5 + ox, height * 0.48 + oy, 30, width * 0.5, height * 0.5, Math.max(width, height) * 0.75);
                g.addColorStop(0, '#1d1b3a');
                g.addColorStop(1, CFG.bgColor);
                ctx.fillStyle = g;
                ctx.fillRect(0, 0, width, height);
              }

              if (CFG.ripple) {
                ctx.save();
                ctx.strokeStyle = `rgba(255, 255, 255, ${(0.07 * CFG.rippleIntensity).toFixed(3)})`;
                ctx.lineWidth = 1.5;
                for (let k = 0; k < 5; k++) {
                  const yBase = height * (0.62 + k * 0.08);
                  ctx.beginPath();
                  for (let x = 0; x <= width; x += 28) {
                    const wy = yBase + Math.sin(x * 0.014 + t * 2.2 + k) * (8 * CFG.rippleIntensity);
                    if (x === 0) ctx.moveTo(x, wy); else ctx.lineTo(x, wy);
                  }
                  ctx.stroke();
                }
                ctx.restore();
              }

              const pSpd = CFG.particleSpeed * spd * (1 + bassBoost * 6);
              if (CFG.particles === 'rain') {
                ctx.strokeStyle = CFG.particleColor;
                ctx.globalAlpha = 0.45;
                ctx.lineWidth = 1.2;
                ctx.beginPath();
                for (const p of parts) {
                  p.y += (8 + p.vy * 5) * pSpd;
                  p.x += 1.2 * pSpd;
                  if (p.y > height) { p.y = -20; p.x = Math.random() * width; }
                  ctx.moveTo(p.x, p.y);
                  ctx.lineTo(p.x + 2, p.y + 18);
                }
                ctx.stroke();
                ctx.globalAlpha = 1;
              } else if (CFG.particles !== 'none') {
                ctx.fillStyle = CFG.particleColor;
                for (const p of parts) {
                  p.p += 0.03 * pSpd;
                  if (CFG.particles === 'snow') {
                    p.y += (0.7 + p.vy * 0.9) * pSpd;
                    p.x += Math.sin(p.p) * 0.6 * pSpd;
                    if (p.y > height) { p.y = -5; p.x = Math.random() * width; }
                  } else if (CFG.particles === 'embers') {
                    p.y -= (0.9 + p.vy * 1.1) * pSpd;
                    p.x += Math.sin(p.p * 1.5) * 0.8 * pSpd;
                    if (p.y < -5) { p.y = height + 5; p.x = Math.random() * width; }
                  } else if (CFG.particles === 'fireflies') {
                    p.x += Math.cos(p.p) * 0.9 * pSpd;
                    p.y += Math.sin(p.p * 0.8) * 0.9 * pSpd;
                    if (p.x < 0) p.x = width; if (p.x > width) p.x = 0;
                    if (p.y < 0) p.y = height; if (p.y > height) p.y = 0;
                  } else {
                    p.x += p.vx * 0.1 * pSpd;
                    if (p.x < 0) p.x = width; if (p.x > width) p.x = 0;
                  }
                  const alpha = CFG.particles === 'stars' ? (0.25 + 0.65 * (Math.sin(p.p) * 0.5 + 0.5)) : p.a;
                  ctx.globalAlpha = alpha;
                  ctx.beginPath();
                  ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
                  ctx.fill();
                }
                ctx.globalAlpha = 1;
              }

              if (CFG.audioReactive && audioBass > 0.01) {
                const g = ctx.createRadialGradient(width * 0.5, height * 0.5, 50, width * 0.5, height * 0.5, Math.max(width, height) * 0.65);
                g.addColorStop(0, `rgba(124, 58, 237, ${(audioBass * CFG.audioPulse * 0.25).toFixed(3)})`);
                g.addColorStop(1, 'rgba(0,0,0,0)');
                ctx.fillStyle = g;
                ctx.fillRect(0, 0, width, height);
              }
              if (CFG.audioBars) {
                const bw = Math.min(width * 0.72, 920);
                const x0 = (width - bw) * 0.5;
                const step = bw / 64;
                ctx.fillStyle = CFG.particleColor;
                ctx.globalAlpha = 0.65;
                for (let i = 0; i < 64; i++) {
                  const h = 4 + audioSpectrum[i] * 110 * CFG.audioPulse;
                  ctx.fillRect(x0 + i * step, height - 36 - h, Math.max(2, step * 0.6), h);
                }
                ctx.globalAlpha = 1;
              }

              if (CFG.vignette > 0.01) {
                const vg = ctx.createRadialGradient(width * 0.5, height * 0.5, Math.min(width, height) * 0.3, width * 0.5, height * 0.5, Math.max(width, height) * 0.75);
                vg.addColorStop(0, 'rgba(0,0,0,0)');
                vg.addColorStop(1, `rgba(0,0,0,${CFG.vignette.toFixed(2)})`);
                ctx.fillStyle = vg;
                ctx.fillRect(0, 0, width, height);
              }

              if (CFG.clock) {
                const now = new Date();
                const hh = String(now.getHours()).padStart(2, '0');
                const mm = String(now.getMinutes()).padStart(2, '0');
                const timeStr = `${hh}:${mm}`;
                const dateStr = now.toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' }).toUpperCase();

                ctx.save();
                ctx.fillStyle = 'rgba(255, 255, 255, 0.92)';
                ctx.font = '200 92px -apple-system, BlinkMacSystemFont, sans-serif';
                let cx = width * 0.5, cy = height * 0.48;
                ctx.textAlign = 'center';
                if (CFG.clockPos === 'topLeft') { cx = 72; cy = 140; ctx.textAlign = 'left'; }
                else if (CFG.clockPos === 'topRight') { cx = width - 72; cy = 140; ctx.textAlign = 'right'; }
                else if (CFG.clockPos === 'bottomLeft') { cx = 72; cy = height - 96; ctx.textAlign = 'left'; }
                ctx.fillText(timeStr, cx, cy);
                ctx.font = '500 16px -apple-system, BlinkMacSystemFont, sans-serif';
                ctx.fillStyle = 'rgba(255, 255, 255, 0.65)';
                ctx.fillText(dateStr, cx, cy + 32);
                ctx.restore();
              }

              requestAnimationFrame(draw);
            }
            requestAnimationFrame(draw);
          </script>
        </body>
        </html>
"""
    }

    public static func exportScene(config: SceneProjectConfig) throws -> WallpaperItem {
        let folderID = UUID().uuidString
        let folderURL = customScenesDirectory.appendingPathComponent(folderID, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var bgRelPath: String? = nil
        var previewPath: String? = nil

        if let srcPath = config.backgroundImagePath, FileManager.default.fileExists(atPath: srcPath) {
            let srcURL = URL(fileURLWithPath: srcPath)
            let ext = srcURL.pathExtension.isEmpty ? "png" : srcURL.pathExtension
            let destFileName = "background.\(ext)"
            let destURL = folderURL.appendingPathComponent(destFileName)
            try? FileManager.default.copyItem(at: srcURL, to: destURL)
            bgRelPath = destFileName
            previewPath = destURL.path
        }

        let html = generateHTML(config: config, imageRelativeSrc: bgRelPath)
        let indexURL = folderURL.appendingPathComponent("index.html")
        try html.write(to: indexURL, atomically: true, encoding: .utf8)

        let projectDict: [String: Any] = [
            "title": config.title,
            "type": "web",
            "file": "index.html",
            "preview": bgRelPath ?? "",
            "tags": ["Custom Scene", config.particlePreset.displayName],
            "general": [
                "properties": [
                    "particlespeed": ["text": "Particle Speed", "type": "slider", "value": config.particleSpeed, "min": 0.25, "max": 2.5],
                    "parallaxstrength": ["text": "Parallax Strength", "type": "slider", "value": config.parallaxStrength, "min": 0, "max": 45],
                    "showclock": ["text": "Show Clock", "type": "bool", "value": config.clockEnabled],
                    "audiobars": ["text": "Audio Spectrum Bars", "type": "bool", "value": config.audioBarsEnabled]
                ]
            ]
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: projectDict, options: [.prettyPrinted]) {
            try? jsonData.write(to: folderURL.appendingPathComponent("project.json"))
        }

        if case .success(var parsed) = WallpaperEngineParser.parseFolderResult(at: folderURL, source: .localImport) {
            if parsed.previewPath == nil { parsed.previewPath = previewPath }
            return parsed
        }

        return WallpaperItem(
            id: folderID,
            title: config.title,
            type: .web,
            pathOrURL: indexURL.path,
            previewPath: previewPath,
            isBuiltIn: false,
            tags: ["Custom Scene"],
            resolutionLabel: "Custom 2D Scene",
            source: .localImport
        )
    }
}
