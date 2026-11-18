import Cocoa
import WebKit

public class WebWallpaperView: NSView, WKNavigationDelegate {
    private var webView: WKWebView?
    private var lastLoadedURL: URL?
    private var isCurrentlyPaused: Bool = false
    private var isCurrentlyMuted: Bool = true
    private var currentVolume: Float = 0.5
    private var currentProperties: WallpaperProperties = .default
    private var currentGlobalFPSCap: Int = 60

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    private static let engineBridgeScript: String = """
    (function() {
      if (window.__nimbscapeBridgeInstalled) return;
      window.__nimbscapeBridgeInstalled = true;

      window.__nsPaused = false;
      window.__nsFpsCap = 60;
      window.__nsBaseSpeed = 1.0;
      window.__nsSpeed = 1.0;

      const nativeRAF = window.requestAnimationFrame.bind(window);
      const nativeCancelRAF = window.cancelAnimationFrame.bind(window);

      let pendingCallbacks = new Map();
      let nextHandle = 1;
      let lastFrameTime = performance.now();
      let virtualTime = lastFrameTime;
      let driverScheduled = false;
      let sleepTimerId = null;
      let hasPaintedFirstFrame = false;
      let forceOneFrame = false;
      let rampActive = false;
      let rampStartTime = 0;
      let rampDurationMs = 0;

      function scheduleNextFrame() {
        if (driverScheduled || sleepTimerId !== null) return;
        const allowFrame = !window.__nsPaused || !hasPaintedFirstFrame || forceOneFrame || rampActive;
        if (!allowFrame || pendingCallbacks.size === 0) return;

        const fps = window.__nsFpsCap || 60;
        if (!forceOneFrame && !rampActive && hasPaintedFirstFrame && fps < 55) {
          const minInterval = 1000 / fps;
          const elapsed = performance.now() - lastFrameTime;
          const waitMs = minInterval - elapsed - 2;
          if (waitMs > 4) {
            sleepTimerId = setTimeout(() => {
              sleepTimerId = null;
              if ((!window.__nsPaused || rampActive) && pendingCallbacks.size > 0 && !driverScheduled) {
                driverScheduled = true;
                nativeRAF(step);
              }
            }, waitMs);
            return;
          }
        }
        driverScheduled = true;
        nativeRAF(step);
      }

      function step(now) {
        driverScheduled = false;
        const allowFrame = !window.__nsPaused || !hasPaintedFirstFrame || forceOneFrame || rampActive;
        if (!allowFrame) {
          lastFrameTime = now;
          return;
        }
        const minInterval = (window.__nsFpsCap > 0 && !forceOneFrame && !rampActive && hasPaintedFirstFrame)
          ? (1000 / window.__nsFpsCap)
          : 0;
        const dt = now - lastFrameTime;
        if (dt + 0.5 < minInterval) {
          scheduleNextFrame();
          return;
        }
        lastFrameTime = now;

        if (rampActive) {
          const t = rampDurationMs > 0 ? Math.min(1, (now - rampStartTime) / rampDurationMs) : 1;

          const factor = (1 - t) * (1 - t);
          window.__nsSpeed = window.__nsBaseSpeed * factor;
          document.documentElement.style.setProperty('--ns-speed', String(window.__nsSpeed));
          document.querySelectorAll('video, audio').forEach(el => {
            el.playbackRate = Math.max(0.0625, window.__nsSpeed);
          });
          if (t >= 1) {
            rampActive = false;
            window.__nsSpeed = 0;
            window.__nsSetPaused(true);
            return;
          }
        }

        virtualTime += dt * (window.__nsSpeed || 0);
        hasPaintedFirstFrame = true;
        forceOneFrame = false;

        const batch = Array.from(pendingCallbacks.entries());
        pendingCallbacks.clear();
        for (const [, cb] of batch) {
          try { cb(virtualTime); } catch (e) {}
        }
        scheduleNextFrame();
      }

      window.requestAnimationFrame = function(cb) {
        const id = nextHandle++;
        pendingCallbacks.set(id, cb);
        scheduleNextFrame();
        return id;
      };

      window.cancelAnimationFrame = function(id) {
        pendingCallbacks.delete(id);
        nativeCancelRAF(id);
      };

      window.__nsForceRepaint = function() {
        forceOneFrame = true;
        if (sleepTimerId !== null) {
          clearTimeout(sleepTimerId);
          sleepTimerId = null;
        }
        scheduleNextFrame();
      };

      window.__nsRampToStop = function(durationSeconds) {
        const ms = Math.max(200, (Number(durationSeconds) || 3.0) * 1000);
        rampActive = true;
        rampStartTime = performance.now();
        rampDurationMs = ms;
        window.__nsPaused = false;
        window.__nsSpeed = window.__nsBaseSpeed;
        if (sleepTimerId !== null) {
          clearTimeout(sleepTimerId);
          sleepTimerId = null;
        }
        if (document.body) {
          document.body.style.animationPlayState = 'running';
        }
        document.querySelectorAll('video, audio').forEach(el => {
          el.playbackRate = window.__nsBaseSpeed;
          el.play().catch(() => {});
        });
        lastFrameTime = performance.now();
        scheduleNextFrame();
      };

      window.__nsCancelRamp = function() {
        rampActive = false;
        window.__nsSpeed = window.__nsBaseSpeed;
        document.documentElement.style.setProperty('--ns-speed', String(window.__nsBaseSpeed));
        document.querySelectorAll('video, audio').forEach(el => {
          el.playbackRate = window.__nsBaseSpeed;
        });
      };

      window.__nsSetPaused = function(paused) {
        if (!paused) {
          rampActive = false;
          window.__nsSpeed = window.__nsBaseSpeed;
          document.documentElement.style.setProperty('--ns-speed', String(window.__nsBaseSpeed));
        }
        window.__nsPaused = !!paused;
        if (paused && sleepTimerId !== null) {
          clearTimeout(sleepTimerId);
          sleepTimerId = null;
        }
        if (document.body) {
          document.body.style.animationPlayState = paused ? 'paused' : 'running';
        }
        document.querySelectorAll('video, audio').forEach(el => {
          if (paused) el.pause(); else {
            el.playbackRate = window.__nsBaseSpeed;
            el.play().catch(() => {});
          }
        });
        if (!paused) {
          lastFrameTime = performance.now();
          scheduleNextFrame();
        }
        if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.setPaused === 'function') {
          try { window.wallpaperPropertyListener.setPaused(!!paused); } catch (e) {}
        }
      };

      window.__nsSetFPSCap = function(fps) {
        window.__nsFpsCap = Math.max(15, Number(fps) || 60);
      };

      window.__nsSetSpeed = function(speed) {
        const s = Math.max(0.25, Math.min(2.0, Number(speed) || 1.0));
        window.__nsBaseSpeed = s;
        if (!rampActive) {
          window.__nsSpeed = s;
          document.documentElement.style.setProperty('--ns-speed', String(s));
          document.querySelectorAll('video, audio').forEach(el => {
            el.playbackRate = s;
          });
        }
      };

      window.__nsApplyVisuals = function(hue, brightness, contrast, saturation, objectFit) {
        const isNeutral = Math.abs(hue) < 0.01
          && Math.abs(brightness - 1.0) < 0.01
          && Math.abs(contrast - 1.0) < 0.01
          && Math.abs(saturation - 1.0) < 0.01;
        document.documentElement.style.filter = isNeutral
          ? ''
          : `hue-rotate(${hue}deg) brightness(${brightness}) contrast(${contrast}) saturate(${saturation})`;
        document.documentElement.style.setProperty('--pe-alignment', objectFit);

        let styleEl = document.getElementById('pe-alignment-style');
        if (!styleEl) {
          styleEl = document.createElement('style');
          styleEl.id = 'pe-alignment-style';
          (document.head || document.documentElement).appendChild(styleEl);
        }
        styleEl.textContent = `video, img, canvas { object-fit: ${objectFit}; }`;
      };

      window.__nsSetAudio = function(muted, volume) {
        document.querySelectorAll('video, audio').forEach(el => {
          el.muted = !!muted;
          el.volume = Math.max(0, Math.min(1, Number(volume) || 0));
        });
      };

      window.__nsApplyUserProperties = function(rawProps) {
        if (!rawProps || typeof rawProps !== 'object') return;
        const mapped = {};
        for (const [k, v] of Object.entries(rawProps)) {
          let parsed = v;
          if (v === 'true') parsed = true;
          else if (v === 'false') parsed = false;
          else if (v !== '' && !isNaN(Number(v)) && !String(v).includes(' ')) parsed = Number(v);
          mapped[k] = { value: parsed };
        }
        if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.applyUserProperties === 'function') {
          try { window.wallpaperPropertyListener.applyUserProperties(mapped); } catch (e) {}
        }
      };

      let audioListeners = [];
      window.wallpaperRegisterAudioListener = function(cb) {
        if (typeof cb === 'function') {
          audioListeners.push(cb);
        }
      };
      window.__nsPushAudio = function(arr) {
        if (!audioListeners.length || window.__nsPaused) return;
        for (let i = 0; i < audioListeners.length; i++) {
          try { audioListeners[i](arr); } catch (e) {}
        }
      };

      window.__nsMouseMove = function(nx, ny) {
        if (window.__nsPaused) return;
        try {
          window.dispatchEvent(new CustomEvent('ns-mousemove', { detail: { x: nx, y: ny } }));
        } catch (e) {}
      };
    })();
"""

    public func loadWeb(
        url: URL,
        isPaused: Bool,
        isMuted: Bool = true,
        volume: Float = 0.5,
        properties: WallpaperProperties = .default,
        globalFPSCap: Int = 60
    ) {
        cleanup()

        self.lastLoadedURL = url
        self.isCurrentlyPaused = isPaused
        self.isCurrentlyMuted = isMuted
        self.currentVolume = volume
        self.currentProperties = properties
        self.currentGlobalFPSCap = globalFPSCap

        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let userScript = WKUserScript(
            source: Self.engineBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)

        let wv = WKWebView(frame: self.bounds, configuration: configuration)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")

        self.addSubview(wv)
        self.webView = wv

        loadIntoWebView(wv, url: url)
    }

    private func loadIntoWebView(_ wv: WKWebView, url: URL) {
        if url.isFileURL {
            let directoryURL = url.deletingLastPathComponent()
            wv.loadFileURL(url, allowingReadAccessTo: directoryURL)
        } else {
            let request = URLRequest(url: url)
            wv.load(request)
        }
    }

    public var onDidFinishLoad: (() -> Void)?

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncAllStateToWebView()
        onDidFinishLoad?()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = lastLoadedURL {
            loadIntoWebView(webView, url: url)
        }
    }

    public func recoverAfterWake() {
        guard let wv = webView else { return }
        if wv.url == nil, let url = lastLoadedURL {
            loadIntoWebView(wv, url: url)
            return
        }
        wv.evaluateJavaScript("window.__nsForceRepaint && window.__nsForceRepaint();", completionHandler: nil)
    }

    public func captureSnapshot(completion: @escaping @MainActor (NSImage?) -> Void) {
        guard let wv = webView, wv.bounds.width > 10, wv.bounds.height > 10 else {
            completion(nil)
            return
        }
        let config = WKSnapshotConfiguration()
        config.rect = wv.bounds
        wv.takeSnapshot(with: config) { image, _ in
            Task { @MainActor in
                completion(image)
            }
        }
    }

    private func syncAllStateToWebView() {
        applyProperties(currentProperties, globalFPSCap: currentGlobalFPSCap)
        setAudio(muted: isCurrentlyMuted, volume: currentVolume)
        if isCurrentlyPaused {
            pause()
        } else {
            play()
        }
    }

    public func applyProperties(_ properties: WallpaperProperties, globalFPSCap: Int = 60) {
        self.currentProperties = properties
        self.currentGlobalFPSCap = globalFPSCap

        let effectiveFPS = min(properties.fpsCap, globalFPSCap)
        let objectFit: String
        switch properties.alignment {
        case .fill: objectFit = "cover"
        case .fit: objectFit = "contain"
        case .stretch: objectFit = "fill"
        }

        let visualJS = """
        window.__nsSetFPSCap && window.__nsSetFPSCap(\(effectiveFPS));
        window.__nsSetSpeed && window.__nsSetSpeed(\(properties.speed));
        window.__nsApplyVisuals && window.__nsApplyVisuals(\(properties.hue), \(properties.brightness), \(properties.contrast), \(properties.saturation), '\(objectFit)');
"""
        webView?.evaluateJavaScript(visualJS, completionHandler: nil)

        if !properties.customProps.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: properties.customProps),
           let json = String(data: data, encoding: .utf8) {
            let propJS = "window.__nsApplyUserProperties && window.__nsApplyUserProperties(\(json));"
            webView?.evaluateJavaScript(propJS, completionHandler: nil)
        }
    }

    public func play() {
        isCurrentlyPaused = false
        webView?.evaluateJavaScript("window.__nsSetPaused && window.__nsSetPaused(false);", completionHandler: nil)
    }

    public func pause() {
        isCurrentlyPaused = true
        webView?.evaluateJavaScript("window.__nsSetPaused && window.__nsSetPaused(true);", completionHandler: nil)
    }

    public func startSlowStop(duration: Double) {
        isCurrentlyPaused = false
        let duration = max(0.2, duration)
        webView?.evaluateJavaScript("window.__nsRampToStop && window.__nsRampToStop(\(duration));", completionHandler: nil)
    }

    public func cancelSlowStop() {
        webView?.evaluateJavaScript("window.__nsCancelRamp && window.__nsCancelRamp();", completionHandler: nil)
    }

    public func pushAudioSpectrum(_ bands128: [Float]) {
        guard !isCurrentlyPaused, let wv = webView, bands128.count == 128 else { return }
        var parts = [String]()
        parts.reserveCapacity(128)
        for v in bands128 {
            parts.append(String(format: "%.3f", v))
        }
        let js = "window.__nsPushAudio && window.__nsPushAudio([\(parts.joined(separator: ","))]);"
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    public func pushMousePosition(normX: Double, normY: Double) {
        guard !isCurrentlyPaused, let wv = webView else { return }
        let js = String(format: "window.__nsMouseMove && window.__nsMouseMove(%.3f, %.3f);", normX, normY)
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    public func setMuted(_ muted: Bool) {
        isCurrentlyMuted = muted
        setAudio(muted: muted, volume: currentVolume)
    }

    public func setVolume(_ volume: Float) {
        currentVolume = volume
        setAudio(muted: isCurrentlyMuted, volume: volume)
    }

    private func setAudio(muted: Bool, volume: Float) {
        let js = "window.__nsSetAudio && window.__nsSetAudio(\(muted ? "true" : "false"), \(volume));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    public func cleanup() {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.removeFromSuperview()
        webView = nil
    }
}
