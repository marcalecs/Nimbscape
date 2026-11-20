import Cocoa
import Combine
import WebKit
import SwiftUI

/// One HTML widget in the catalog (`index.json`).
public struct CatalogWidget: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let author: String
    public let version: String
    public let symbol: String
    public let width: Double
    public let height: Double
    /// Files relative to the widget folder; `index.html` is the entry point.
    public let files: [String]
}

private struct CatalogIndex: Codable {
    let widgets: [CatalogWidget]
}

/// The widget store: lists the catalog and installs widgets into Application Support.
///
/// The catalog is read from the Nimbscape GitHub repository (`widgets` branch) and falls back to
/// the copy bundled with the app, so the store works offline and before the branch exists.
@MainActor
public final class WidgetCatalog: ObservableObject {
    public static let shared = WidgetCatalog()

    @Published public private(set) var widgets: [CatalogWidget] = []
    @Published public private(set) var installed: [String: CatalogWidget] = [:]
    @Published public private(set) var isLoading = false
    @Published public private(set) var installingID: String?
    @Published public private(set) var errorMessage: String?

    private nonisolated static let remoteBase = URL(string: "https://raw.githubusercontent.com/marcalecs/Nimbscape/widgets/catalog/")!
    private static var bundledBase: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("WidgetCatalog", isDirectory: true)
    }

    public static var installDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Nimbscape/Widgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        loadInstalled()
    }

    public func folder(for id: String) -> URL {
        Self.installDirectory.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: Listing

    public func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            defer { self.isLoading = false }
            if let remote = try? await Self.fetchIndex(base: Self.remoteBase) {
                self.widgets = remote.widgets
            } else if let base = Self.bundledBase,
                      let data = try? Data(contentsOf: base.appendingPathComponent("index.json")),
                      let bundled = try? JSONDecoder().decode(CatalogIndex.self, from: data) {
                self.widgets = bundled.widgets
            } else {
                self.errorMessage = "Widget store is unavailable right now."
            }
        }
    }

    private nonisolated static func fetchIndex(base: URL) async throws -> CatalogIndex {
        var request = URLRequest(url: base.appendingPathComponent("index.json"))
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CatalogIndex.self, from: data)
    }

    // MARK: Installing

    public func install(_ widget: CatalogWidget) async -> Bool {
        if installed[widget.id]?.version == widget.version { return true }
        installingID = widget.id
        defer { installingID = nil }
        let target = folder(for: widget.id)
        let staging = Self.installDirectory.appendingPathComponent(".staging-\(widget.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in widget.files {
                guard CoreRules.isSafeRelativePath(file) else { throw URLError(.badURL) }
                let destination = staging.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try await Self.loadFile(widgetID: widget.id, file: file)
                try data.write(to: destination)
            }
            let manifest = try JSONEncoder().encode(widget)
            try manifest.write(to: staging.appendingPathComponent("manifest.json"))
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staging, to: target)
            installed[widget.id] = widget
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            errorMessage = "Couldn't install \(widget.name)."
            return false
        }
    }

    public func uninstall(_ id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
        installed[id] = nil
    }

    private nonisolated static func loadFile(widgetID: String, file: String) async throws -> Data {
        let remote = remoteBase.appendingPathComponent(widgetID).appendingPathComponent(file)
        if let (data, response) = try? await URLSession.shared.data(from: remote),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            return data
        }
        guard let base = await MainActor.run(body: { bundledBase }) else { throw URLError(.fileDoesNotExist) }
        return try Data(contentsOf: base.appendingPathComponent(widgetID).appendingPathComponent(file))
    }


    private func loadInstalled() {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: Self.installDirectory, includingPropertiesForKeys: nil) else { return }
        for folder in folders where !folder.lastPathComponent.hasPrefix(".") {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
               let widget = try? JSONDecoder().decode(CatalogWidget.self, from: data) {
                installed[widget.id] = widget
            }
        }
    }
}

// MARK: - Sandboxed renderer

/// Shows an installed HTML widget. Network loads are blocked by a content rule list, and the page
/// may only read its own folder, so store widgets can't reach the internet or the rest of the disk.
struct CatalogWidgetWebView: NSViewRepresentable {
    let widgetID: String
    let interactive: Bool
    var instanceID: UUID? = nil

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The app draws the card; a widget's own card background/border would double it.
        let css = "html,body{background:transparent!important}.card{background:transparent!important;border:none!important;box-shadow:none!important}"
        configuration.userContentController.addUserScript(WKUserScript(
            source: "var s=document.createElement('style');s.textContent='\(css)';document.documentElement.appendChild(s);",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = SandboxedWidgetWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        if let instanceID { WebWidgetBridge.register(webView, for: instanceID) }
        WidgetSandbox.applyRules(to: configuration.userContentController) {
            let folder = WidgetCatalog.shared.folder(for: widgetID)
            webView.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        (webView as? SandboxedWidgetWebView)?.acceptsClicks = interactive
    }
}

final class SandboxedWidgetWebView: WKWebView {
    var acceptsClicks = true
    override func hitTest(_ point: NSPoint) -> NSView? { acceptsClicks ? super.hitTest(point) : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
enum WidgetSandbox {
    private static var compiled: WKContentRuleList?

    static func applyRules(to controller: WKUserContentController, then load: @escaping @MainActor () -> Void) {
        if let compiled {
            controller.add(compiled)
            load()
            return
        }
        // WebKit content-blocker regexes don't support alternation, so one rule per scheme family.
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "nimbscape.widget.sandbox", encodedContentRuleList: rules) { list, _ in
            MainActor.assumeIsolated {
                if let list {
                    compiled = list
                    controller.add(list)
                    load()
                }
                // If the rules failed to compile, the widget is not loaded at all.
            }
        }
    }
}


/// Visible web widgets by placed-widget ID, so the click layer can forward clicks to them.
@MainActor
enum WebWidgetBridge {
    private final class WeakView { weak var view: WKWebView?; init(_ v: WKWebView) { view = v } }
    private static var views: [UUID: WeakView] = [:]

    static func register(_ webView: WKWebView, for id: UUID) {
        views = views.filter { $0.value.view != nil }
        views[id] = WeakView(webView)
    }

    /// Dispatches a click at a point in the widget's own coordinates (CSS pixels).
    static func click(_ id: UUID, at point: CGPoint) {
        guard let webView = views[id]?.view else { return }
        let x = Int(point.x.rounded()), y = Int(point.y.rounded())
        let script = """
        (function(){var e=document.elementFromPoint(\(x),\(y));if(!e)return;
        ['mousedown','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,clientX:\(x),clientY:\(y),view:window}));});})();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
