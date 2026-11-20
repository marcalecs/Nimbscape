import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Shared editing state for the widget overlay.
@MainActor
public final class OverlayEditorState: ObservableObject {
    public static let shared = OverlayEditorState()
    @Published public var isEditing = false
    @Published public var selectedWidgetID: UUID?
}

/// `desktop`: visible widgets inside the wallpaper window (no input).
/// `hitLayer`: invisible copy above the desktop icons that receives clicks.
/// `editor`: the full-screen editor.
enum OverlayCanvasMode { case desktop, hitLayer, editor }

private struct WidgetSizeKey: PreferenceKey {
    static let defaultValue: [UUID: CGSize] = [:]
    static func reduce(value: inout [UUID: CGSize], nextValue: () -> [UUID: CGSize]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Corner handles for resizing; the opposite corner stays fixed.
private enum ResizeCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Direction the dragged corner moves away from the anchor (+1 right/down, -1 left/up).
    var sx: CGFloat { self == .topRight || self == .bottomRight ? 1 : -1 }
    var sy: CGFloat { self == .bottomLeft || self == .bottomRight ? 1 : -1 }
    var layoutCorner: OverlayLayout.Corner {
        switch self {
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        }
    }
    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

/// A snapping guide drawn while dragging or resizing.
private struct SnapGuide: Hashable {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    let position: CGFloat
}

// MARK: - Canvas

/// Lays out one wallpaper's widgets over a display: read-only (but clickable) on the desktop,
/// fully editable in the full-screen editor.
struct OverlayCanvasView: View {
    let wallpaperID: String
    let displayID: String
    let mode: OverlayCanvasMode
    let insets: EdgeInsets
    var onDone: () -> Void

    @ObservedObject private var store = OverlayStore.shared
    @ObservedObject private var editor = OverlayEditorState.shared
    @ObservedObject private var visibleSizes = VisibleWidgetSizes.shared

    @State private var sizes: [UUID: CGSize] = [:]
    @State private var liveCenters: [UUID: CGPoint] = [:]
    @State private var dragOrigins: [UUID: CGPoint] = [:]
    @State private var liveScales: [UUID: Double] = [:]
    @State private var resizeOrigins: [UUID: CGRect] = [:]   // widget frame when the resize began
    @State private var guides: [SnapGuide] = []
    @State private var isDropTargeted = false
    @State private var showGallery = false
    @State private var snapState = OverlayLayout.SnapState()

    private var config: OverlayConfig { store.config(for: wallpaperID) }
    private var isEditor: Bool { mode == .editor }
    private static let canvasSpace = "nimbscape.overlay.canvas"

    var body: some View {
        GeometryReader { proxy in
            let canvas = proxy.size
            ZStack(alignment: .topLeading) {
                if isEditor {
                    Color.black.opacity(0.3)
                        .contentShape(Rectangle())
                        .onTapGesture { editor.selectedWidgetID = nil }
                    safeAreaOutline(canvas)
                }

                // On the desktop the widgets step aside while the editor shows its own copies.
                if isEditor || !editor.isEditing {
                    ForEach(config.widgets) { widget in
                        widgetItem(widget, canvas: canvas)
                    }
                }

                if isEditor {
                    guidesView(canvas)
                    inspectorCard(canvas)
                    OverlayEditorToolbar(wallpaperID: wallpaperID, showGallery: $showGallery, onDone: onDone)
                        .frame(width: canvas.width)
                        .padding(.top, insets.top)
                    if showGallery {
                        WidgetGalleryPanel(onClose: { showGallery = false }) { payload in
                            add(payload, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2), canvas: canvas)
                            showGallery = false
                        }
                        .frame(width: 280, height: min(560, max(200, canvas.height - insets.top - insets.bottom - 70)))
                        .padding(.leading, insets.leading)
                        .padding(.top, insets.top + 64)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .coordinateSpace(name: Self.canvasSpace)
            .onPreferenceChange(WidgetSizeKey.self) { measured in
                sizes = measured
                if mode == .desktop { VisibleWidgetSizes.shared.set(measured, displayID: displayID) }
                registerHits(canvas)
            }
            .onChange(of: config) { registerHits(canvas) }
            .onChange(of: canvas) { registerHits(canvas) }
            .dropDestination(for: String.self) { items, location in
                guard isEditor, let payload = items.first else { return false }
                add(payload, at: location, canvas: canvas)
                showGallery = false
                return true
            } isTargeted: { isDropTargeted = $0 }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.2), value: showGallery)
    }

    // MARK: Inspector card (next to the selected widget)

    @ViewBuilder
    private func inspectorCard(_ canvas: CGSize) -> some View {
        if let id = editor.selectedWidgetID,
           let widget = config.widgets.first(where: { $0.id == id }),
           dragOrigins[id] == nil, resizeOrigins[id] == nil {
            let frame = frameOf(widget, canvas: canvas)
            let cardWidth: CGFloat = 270, cardHeight: CGFloat = 230
            let fitsRight = frame.maxX + 20 + cardWidth <= canvas.width - insets.trailing
            let x = fitsRight ? frame.maxX + 20 + cardWidth / 2 : max(insets.leading + cardWidth / 2, frame.minX - 20 - cardWidth / 2)
            let y = min(max(frame.midY, insets.top + cardHeight / 2), canvas.height - insets.bottom - cardHeight / 2)
            WidgetInspector(wallpaperID: wallpaperID, widget: widget)
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                .position(x: x, y: y)
                .transition(.opacity)
        }
    }

    // MARK: Widget item

    @ViewBuilder
    private func widgetItem(_ widget: OverlayWidget, canvas: CGSize) -> some View {
        let scale = liveScales[widget.id] ?? widget.scale
        let base = sizes[widget.id] ?? .zero
        let scaled = CGSize(width: base.width * scale, height: base.height * scale)
        let center = liveCenters[widget.id] ?? clamp(pixelCenter(of: widget, canvas: canvas), size: scaled, canvas: canvas)
        let isSelected = isEditor && editor.selectedWidgetID == widget.id

        Group {
            if mode == .hitLayer && widget.kind == .custom {
                // Web widgets aren't duplicated: clicks are forwarded to the visible copy.
                // Sized from the catalog manifest like the visible copy (not from its own
                // measurement, which starts at zero and would keep the catcher 1×1).
                WebWidgetClickCatcher(widgetID: widget.id, size: catalogSize(of: widget))
            } else if mode == .hitLayer && widget.kind != .nowPlaying {
                // Only Now Playing has buttons; other widgets need a plain hit area sized like
                // the visible copy, not a second full rendering.
                hitArea(for: widget)
            } else {
                WidgetCardView(widget: widget, interactive: mode == .hitLayer,
                               instanceID: mode == .desktop ? widget.id : nil)
                    .opacity(mode == .hitLayer ? 0.011 : 1)
            }
        }
            .background(GeometryReader { geo in
                Color.clear.preference(key: WidgetSizeKey.self, value: [widget.id: geo.size])
            })
            .allowsHitTesting(!isEditor)
            .scaleEffect(scale)
            .frame(width: base == .zero ? nil : scaled.width, height: base == .zero ? nil : scaled.height)
            .overlay {
                if isEditor {
                    editHandles(widget, isSelected: isSelected, canvas: canvas)
                }
            }
            .position(center)
    }

    @ViewBuilder
    private func editHandles(_ widget: OverlayWidget, isSelected: Bool, canvas: CGSize) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // Invisible hit area that owns selection and dragging in the editor.
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(moveGesture(widget, canvas: canvas))
                .onTapGesture { editor.selectedWidgetID = widget.id }

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-6)
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(false)

            if isSelected {
                ForEach(ResizeCorner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .shadow(radius: 2)
                        .frame(width: 32, height: 32)          // larger grab area
                        .contentShape(Rectangle())
                        .offset(x: corner.sx * 14, y: corner.sy * 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                        .gesture(resizeGesture(widget, corner: corner, canvas: canvas))
                }
            }
        }
    }

    // MARK: Gestures

    private func moveGesture(_ widget: OverlayWidget, canvas: CGSize) -> some Gesture {
        // Measured in the fixed canvas space: in the widget's own (moving) space the translation
        // feeds back into itself every frame and the drag shakes.
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                editor.selectedWidgetID = widget.id
                let size = scaledSize(widget)
                let origin = dragOrigins[widget.id] ?? clamp(pixelCenter(of: widget, canvas: canvas), size: size, canvas: canvas)
                dragOrigins[widget.id] = origin
                let proposed = CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)
                var state = snapState
                let snapped = OverlayLayout.snap(
                    proposed: proposed, size: size,
                    others: otherFrames(excluding: widget.id, canvas: canvas), canvas: canvas,
                    speed: hypot(value.velocity.width, value.velocity.height),
                    disabled: NSEvent.modifierFlags.contains(.command), state: &state
                )
                snapState = state
                liveCenters[widget.id] = clamp(snapped.center, size: size, canvas: canvas)
                guides = guideLines(x: snapped.guideX, y: snapped.guideY)
            }
            .onEnded { _ in
                if let center = liveCenters[widget.id] {
                    commit(widget.id) { $0.center = CGPoint(x: center.x / max(canvas.width, 1), y: center.y / max(canvas.height, 1)) }
                }
                liveCenters[widget.id] = nil
                dragOrigins[widget.id] = nil
                guides = []
                snapState = OverlayLayout.SnapState()
            }
    }

    /// Resizes from one corner while the opposite corner stays put. The moving edges snap to the
    /// edges of other widgets and the size stays within the safe area.
    private func resizeGesture(_ widget: OverlayWidget, corner: ResizeCorner, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                guard let base = sizes[widget.id], base.width > 0, base.height > 0 else { return }
                editor.selectedWidgetID = widget.id
                let start = resizeOrigins[widget.id] ?? frameOf(widget, canvas: canvas)
                resizeOrigins[widget.id] = start

                let result = OverlayLayout.resize(
                    start: start, baseSize: base, corner: corner.layoutCorner, translation: value.translation,
                    others: otherFrames(excluding: widget.id, canvas: canvas), canvas: canvas, insets: layoutInsets,
                    snapping: !NSEvent.modifierFlags.contains(.command)
                )
                guides = guideLines(x: result.guideX, y: result.guideY)
                liveScales[widget.id] = result.scale
                liveCenters[widget.id] = result.center
            }
            .onEnded { _ in
                if let scale = liveScales[widget.id], let center = liveCenters[widget.id] {
                    commit(widget.id) {
                        $0.scale = scale
                        $0.center = CGPoint(x: center.x / max(canvas.width, 1), y: center.y / max(canvas.height, 1))
                    }
                }
                liveScales[widget.id] = nil
                liveCenters[widget.id] = nil
                resizeOrigins[widget.id] = nil
                guides = []
            }
    }

    // MARK: Geometry

    private func scaledSize(_ widget: OverlayWidget) -> CGSize {
        let base = sizes[widget.id] ?? .zero
        let scale = liveScales[widget.id] ?? widget.scale
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    private func pixelCenter(of widget: OverlayWidget, canvas: CGSize) -> CGPoint {
        CGPoint(x: widget.center.x * canvas.width, y: widget.center.y * canvas.height)
    }

    private func frameOf(_ widget: OverlayWidget, canvas: CGSize) -> CGRect {
        let size = scaledSize(widget)
        let center = liveCenters[widget.id] ?? clamp(pixelCenter(of: widget, canvas: canvas), size: size, canvas: canvas)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Invisible barrier: keeps the whole widget inside the safe area (menu bar, Dock, edges).
    private func clamp(_ center: CGPoint, size: CGSize, canvas: CGSize) -> CGPoint {
        OverlayLayout.clamp(center: center, size: size, canvas: canvas, insets: layoutInsets)
    }

    private var layoutInsets: OverlayLayout.Insets {
        OverlayLayout.Insets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing)
    }

    private func otherFrames(excluding id: UUID, canvas: CGSize) -> [CGRect] {
        config.widgets.filter { $0.id != id }.map { frameOf($0, canvas: canvas) }
    }

    @ViewBuilder
    private func hitArea(for widget: OverlayWidget) -> some View {
        let size = visibleSizes.sizes[displayID]?[widget.id] ?? CGSize(width: 1, height: 1)
        Color.white.opacity(0.011)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture {
                switch widget.kind {
                case .weather: WidgetCardView.open(bundleID: "com.apple.weather")
                case .calendar: WidgetCardView.open(bundleID: "com.apple.iCal")
                default: break
                }
            }
    }

    private func catalogSize(of widget: OverlayWidget) -> CGSize {
        guard let id = widget.customID, let item = WidgetCatalog.shared.installed[id] else { return CGSize(width: 1, height: 1) }
        return CGSize(width: item.width, height: item.height)
    }

    private func guideLines(x: CGFloat?, y: CGFloat?) -> [SnapGuide] {
        (x.map { [SnapGuide(axis: .vertical, position: $0)] } ?? []) + (y.map { [SnapGuide(axis: .horizontal, position: $0)] } ?? [])
    }

    private func registerHits(_ canvas: CGSize) {
        guard mode == .hitLayer else { return }
        WidgetHitRegistry.shared.set(config.widgets.map { frameOf($0, canvas: canvas) }, displayID: displayID)
    }

    // MARK: Editing helpers

    private func commit(_ id: UUID, _ change: (inout OverlayWidget) -> Void) {
        store.update(wallpaperID) { config in
            if let index = config.widgets.firstIndex(where: { $0.id == id }) { change(&config.widgets[index]) }
        }
    }

    private func add(_ payload: String, at point: CGPoint, canvas: CGSize) {
        let center = CGPoint(x: point.x / max(canvas.width, 1), y: point.y / max(canvas.height, 1))
        if payload.hasPrefix("builtin:"), let kind = OverlayWidgetKind(rawValue: String(payload.dropFirst(8))) {
            let widget = OverlayWidget(kind: kind, center: center)
            store.update(wallpaperID) { $0.widgets.append(widget) }
            editor.selectedWidgetID = widget.id
        } else if payload.hasPrefix("store:") {
            let id = String(payload.dropFirst(6))
            guard let item = WidgetCatalog.shared.widgets.first(where: { $0.id == id }) ?? WidgetCatalog.shared.installed[id] else { return }
            Task {
                guard await WidgetCatalog.shared.install(item) else { return }
                var widget = OverlayWidget(kind: .custom, center: center)
                widget.customID = id
                store.update(wallpaperID) { $0.widgets.append(widget) }
                editor.selectedWidgetID = widget.id
            }
        }
    }

    private func safeAreaOutline(_ canvas: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.white.opacity(isDropTargeted ? 0.6 : 0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
            .frame(width: canvas.width - insets.leading - insets.trailing,
                   height: canvas.height - insets.top - insets.bottom)
            .offset(x: insets.leading, y: insets.top)
            .allowsHitTesting(false)
    }

    private func guidesView(_ canvas: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(guides, id: \.self) { guide in
                switch guide.axis {
                case .vertical:
                    Rectangle().fill(Color.accentColor).frame(width: 1, height: canvas.height).offset(x: guide.position)
                case .horizontal:
                    Rectangle().fill(Color.accentColor).frame(width: canvas.width, height: 1).offset(y: guide.position)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Editor toolbar (effects + Done)

struct OverlayEditorToolbar: View {
    let wallpaperID: String
    @Binding var showGallery: Bool
    let onDone: () -> Void
    @ObservedObject private var store = OverlayStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showGallery.toggle()
            } label: {
                Label("Add Widgets", systemImage: showGallery ? "xmark.circle.fill" : "plus.circle.fill")
            }
            .buttonStyle(.bordered)

            Divider().frame(height: 18)

            Label("Effects", systemImage: "sparkles").font(.callout.weight(.semibold))

            Picker("", selection: binding(\.effects.particles)) {
                ForEach(OverlayParticles.selectable) { Text($0.displayName).tag($0) }
            }
            .frame(width: 130)

            if store.config(for: wallpaperID).effects.particles != .none {
                Image(systemName: "aqi.low").foregroundStyle(.secondary)
                Slider(value: binding(\.effects.particleDensity), in: 0.1...1)
                    .frame(width: 110)
                    .help("Effect intensity")
            }

            Divider().frame(height: 18)

            Image(systemName: "moon.fill").foregroundStyle(.secondary)
            Slider(value: binding(\.effects.dim), in: 0...0.7)
                .frame(width: 100)
                .help("Dim wallpaper")

            Toggle("Blur", isOn: binding(\.effects.blur))
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider().frame(height: 18)

            Button("Done", action: onDone)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .fixedSize()
    }

    private func binding<T>(_ keyPath: WritableKeyPath<OverlayConfig, T>) -> Binding<T> {
        Binding(
            get: { store.config(for: wallpaperID)[keyPath: keyPath] },
            set: { value in store.update(wallpaperID) { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Gallery (built-in + store)

struct WidgetGalleryPanel: View {
    var onClose: () -> Void = {}
    let onAdd: (String) -> Void
    @ObservedObject private var catalog = WidgetCatalog.shared
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Widgets").font(.title3.weight(.semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: $tab) {
                Text("Built-in").tag(0)
                Text("Store").tag(1)
            }
            .pickerStyle(.segmented)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if tab == 0 {
                        ForEach(OverlayWidgetKind.builtIn) { kind in
                            builtInTile(kind)
                        }
                    } else {
                        storeContent
                    }
                }
                .padding(.vertical, 4)
            }
            Text("Click to add, or drag onto the desktop.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    private func builtInTile(_ kind: OverlayWidgetKind) -> some View {
        let sample = OverlayWidget(kind: kind, center: .zero)
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                WidgetCardView(widget: sample, interactive: false)
                    .scaleEffect(0.48)
                    .allowsHitTesting(false)
            }
            .frame(height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Label(kind.displayName, systemImage: kind.symbolName)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { onAdd("builtin:\(kind.rawValue)") }
        .draggable("builtin:\(kind.rawValue)") {
            Label(kind.displayName, systemImage: kind.symbolName).padding(8).background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    private var storeContent: some View {
        if catalog.isLoading && catalog.widgets.isEmpty {
            ProgressView().padding(.top, 30)
        } else if let error = catalog.errorMessage, catalog.widgets.isEmpty {
            Text(error).foregroundStyle(.secondary).padding(.top, 20)
        } else {
            ForEach(catalog.widgets) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 20))
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.callout.weight(.semibold))
                        Text(item.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("by \(item.author) · v\(item.version)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if catalog.installingID == item.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add") { onAdd("store:\(item.id)") }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .draggable("store:\(item.id)") {
                    Label(item.name, systemImage: item.symbol).padding(8).background(.regularMaterial, in: Capsule())
                }
            }
            Text("Store widgets run sandboxed, without internet access.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Inspector (card next to the widget)

struct WidgetInspector: View {
    let wallpaperID: String
    let widget: OverlayWidget
    @ObservedObject private var store = OverlayStore.shared
    @ObservedObject private var editor = OverlayEditorState.shared
    @State private var cityDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: widget.kind.symbolName)
                .font(.headline)

            Picker("Style", selection: binding(\.style)) {
                ForEach(OverlayWidgetStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            if widget.kind == .clock {
                Picker("Face", selection: binding(\.clockFace)) {
                    ForEach(OverlayClockFace.allCases) { Text($0.displayName).tag($0) }
                }
            }

            if widget.kind == .weather {
                HStack {
                    TextField("City", text: $cityDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitCity)
                    Button("Set", action: commitCity)
                }
            }

            HStack {
                Text("Size \(Int((widget.scale * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset Size") { update { $0.scale = 1 } }.controlSize(.small)
            }

            Button(role: .destructive) {
                store.update(wallpaperID) { $0.widgets.removeAll { $0.id == widget.id } }
                editor.selectedWidgetID = nil
            } label: {
                Label("Remove Widget", systemImage: "trash")
            }
        }
        .frame(width: 250)
        .onAppear { cityDraft = widget.city }
    }

    private var title: String {
        if widget.kind == .custom, let id = widget.customID, let item = WidgetCatalog.shared.installed[id] { return item.name }
        return widget.kind.displayName
    }

    private func commitCity() {
        let city = cityDraft.trimmingCharacters(in: .whitespaces)
        update { $0.city = city }
    }

    private func update(_ change: (inout OverlayWidget) -> Void) {
        store.update(wallpaperID) { config in
            if let i = config.widgets.firstIndex(where: { $0.id == widget.id }) { change(&config.widgets[i]) }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<OverlayWidget, T>) -> Binding<T> {
        Binding(get: { widget[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Widget cards

struct WidgetCardView: View {
    let widget: OverlayWidget
    let interactive: Bool
    /// Set for the visible desktop copy, so clicks from the hit layer can reach web widgets.
    var instanceID: UUID? = nil

    var body: some View {
        if widget.kind == .custom {
            // Store widgets are transparent pages; the app draws the same card as for built-ins.
            customWidget
                .modifier(WidgetCardStyle(style: widget.style, padding: 0))
        } else {
            content
                .foregroundStyle(.white)
                .modifier(WidgetCardStyle(style: widget.style, padding: widget.style == .glass ? 18 : 6))
        }
    }

    @ViewBuilder
    private var customWidget: some View {
        if let id = widget.customID, let item = WidgetCatalog.shared.installed[id] {
            CatalogWidgetWebView(widgetID: id, interactive: interactive, instanceID: instanceID)
                .frame(width: item.width, height: item.height)
        } else {
            Label("Widget not installed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.white)
                .padding(16)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch widget.kind {
        case .clock: ClockWidget(face: widget.clockFace)
        case .system: SystemWidget()
        case .nowPlaying: NowPlayingWidget(interactive: interactive)
        case .weather: WeatherWidget(city: widget.city)
                .onTapGesture { if interactive { Self.open(bundleID: "com.apple.weather") } }
        case .calendar: CalendarWidget()
                .onTapGesture { if interactive { Self.open(bundleID: "com.apple.iCal") } }
        case .custom: EmptyView()
        }
    }

    static func open(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct ClockWidget: View {
    let face: OverlayClockFace

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let date = context.date
            switch face {
            case .large:
                VStack(spacing: 2) {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 76, weight: .thin, design: .rounded))
                        .monospacedDigit()
                    Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .opacity(0.85)
                }
            case .compact:
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text(date, format: .dateTime.weekday(.abbreviated).day())
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .opacity(0.8)
                }
            case .seconds:
                VStack(spacing: 2) {
                    Text(date, format: .dateTime.hour().minute().second())
                        .font(.system(size: 58, weight: .ultraLight, design: .rounded))
                        .monospacedDigit()
                    Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .opacity(0.85)
                }
            }
        }
    }
}

private struct SystemWidget: View {
    @ObservedObject private var stats = SystemStatsProvider.shared

    var body: some View {
        let s = stats.snapshot
        VStack(alignment: .leading, spacing: 9) {
            meter("CPU", symbol: "cpu", value: s.cpuUsage, text: "\(Int(s.cpuUsage * 100))%")
            meter("Memory", symbol: "memorychip",
                  value: s.memoryTotal > 0 ? Double(s.memoryUsed) / Double(s.memoryTotal) : 0,
                  text: ByteCountFormatter.string(fromByteCount: Int64(s.memoryUsed), countStyle: .memory))
            meter("Disk", symbol: "internaldrive",
                  value: s.diskTotal > 0 ? 1 - Double(s.diskFree) / Double(s.diskTotal) : 0,
                  text: "\(ByteCountFormatter.string(fromByteCount: s.diskFree, countStyle: .file)) free")
            if let level = s.batteryLevel {
                meter("Battery", symbol: s.isOnBattery ? "battery.75percent" : "battery.100percent.bolt",
                      value: Double(level) / 100, text: "\(level)%")
            }
        }
        .frame(width: 230)
    }

    private func meter(_ title: String, symbol: String, value: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Text(text).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit().opacity(0.85)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white.opacity(0.9)).frame(width: geo.size.width * min(1, max(0, value)))
                }
            }
            .frame(height: 5)
            .animation(.easeInOut(duration: 0.6), value: value)
        }
    }
}

private struct NowPlayingWidget: View {
    let interactive: Bool
    @ObservedObject private var provider = NowPlayingProvider.shared

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let art = provider.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.15))
                        Image(systemName: "music.note").font(.system(size: 22, weight: .medium))
                    }
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                if let info = provider.info {
                    Text(info.title).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(info.artist).font(.system(size: 12, design: .rounded)).opacity(0.75).lineLimit(1)
                    HStack(spacing: 18) {
                        controlButton("backward.fill") { provider.previous() }
                        controlButton(info.isPlaying ? "pause.fill" : "play.fill") { provider.playPause() }
                        controlButton("forward.fill") { provider.next() }
                    }
                    .padding(.top, 3)
                } else {
                    Text("Nothing Playing").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Spotify or Music").font(.system(size: 12, design: .rounded)).opacity(0.7)
                }
            }
            .frame(width: 170, alignment: .leading)
        }
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
    }
}

private struct WeatherWidget: View {
    let city: String
    @ObservedObject private var provider = WeatherProvider.shared

    var body: some View {
        let key = city.trimmingCharacters(in: .whitespaces)
        Group {
            if key.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "cloud.sun.fill").font(.system(size: 26)).symbolRenderingMode(.multicolor)
                    Text("Set a city").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            } else if let report = provider.reports[key] {
                HStack(spacing: 14) {
                    Image(systemName: report.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 38))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(report.temperature.rounded()))°")
                            .font(.system(size: 40, weight: .light, design: .rounded))
                        Text(report.city).font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("\(report.summary) · H \(Int(report.high.rounded()))° L \(Int(report.low.rounded()))°")
                            .font(.system(size: 11, design: .rounded)).opacity(0.8)
                    }
                }
            } else if let error = provider.errors[key] {
                Text(error).font(.system(size: 12, design: .rounded)).frame(width: 180)
            } else {
                ProgressView().controlSize(.small).frame(width: 60, height: 40)
            }
        }
    }
}

private struct CalendarWidget: View {
    @ObservedObject private var provider = CalendarProvider.shared

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 10) {
                MonthGrid(today: context.date)
                if !provider.accessDenied && !provider.events.isEmpty {
                    Divider().overlay(.white.opacity(0.25))
                    ForEach(provider.events.prefix(3)) { event in
                        HStack(alignment: .top, spacing: 8) {
                            Capsule().fill(Color(hex: event.colorHex)).frame(width: 3, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                                Text(event.isAllDay ? "All day" : event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                    .font(.system(size: 10, design: .rounded)).opacity(0.75)
                            }
                        }
                    }
                } else if provider.accessDenied {
                    Text("Events: allow Calendar access in System Settings → Privacy & Security.")
                        .font(.system(size: 10, design: .rounded)).opacity(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 230, alignment: .leading)
        }
    }
}

/// Month view with the current day highlighted.
private struct MonthGrid: View {
    let today: Date
    private let calendar = Calendar.current

    var body: some View {
        let days = monthDays()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(today, format: .dateTime.month(.wide))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 1, green: 0.32, blue: 0.3))
                    .textCase(.uppercase)
                Text(today, format: .dateTime.year())
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .opacity(0.7)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 3), count: 7), spacing: 4) {
                let symbols = weekdaySymbols()
                ForEach(symbols.indices, id: \.self) { index in
                    Text(symbols[index]).font(.system(size: 10, weight: .semibold, design: .rounded)).opacity(0.55)
                }
                ForEach(days.indices, id: \.self) { index in
                    if let day = days[index] {
                        let isToday = calendar.isDate(day, inSameDayAs: today)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 12, weight: isToday ? .bold : .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 24, height: 22)
                            .background(Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).opacity(isToday ? 1 : 0))
                    } else {
                        Color.clear.frame(width: 24, height: 22)
                    }
                }
            }
        }
    }

    private func monthDays() -> [Date?] { CoreRules.monthDays(for: today, calendar: calendar) }
    private func weekdaySymbols() -> [String] { CoreRules.weekdaySymbols(calendar: calendar) }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x3B82F6
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// Hit-layer stand-in for a web widget: forwards clicks into the visible web view.
private struct WebWidgetClickCatcher: View {
    let widgetID: UUID
    let size: CGSize

    var body: some View {
        Color.white.opacity(0.011)
            .frame(width: max(size.width, 1), height: max(size.height, 1))
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                WebWidgetBridge.click(widgetID, at: location)
            }
    }
}

/// The one card look shared by built-in and store widgets, so every widget has the same glass.
struct WidgetCardStyle: ViewModifier {
    let style: OverlayWidgetStyle
    let padding: CGFloat
    static let cornerRadius: CGFloat = 22
    /// Darkness of the glass: enough for white text on bright wallpapers, still see-through.
    static let tint: Double = 0.24

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background {
                if style == .glass {
                    // See-through glass. A material can't blur the video underneath inside the
                    // wallpaper window and turns into a solid gray card, so the glass is a light
                    // dark tint with a soft top highlight and a thin bright rim instead.
                    shape
                        .fill(.black.opacity(Self.tint))
                        .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                                                           startPoint: .top, endPoint: .center)))
                        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                }
            }
            .clipShape(style == .glass ? AnyShape(shape) : AnyShape(Rectangle()))
            // Minimal style: a soft dark halo plus a tight shadow keep text legible on any wallpaper.
            .shadow(color: .black.opacity(style == .minimal ? 0.55 : 0), radius: 14)
            .shadow(color: .black.opacity(style == .minimal ? 0.5 : 0), radius: 2, y: 1)
            .fixedSize()
    }
}

/// Unscaled sizes of the visible widgets per display, so the click layer can size plain hit
/// areas without rendering the widgets a second time.
@MainActor
final class VisibleWidgetSizes: ObservableObject {
    static let shared = VisibleWidgetSizes()
    @Published private(set) var sizes: [String: [UUID: CGSize]] = [:]

    func set(_ measured: [UUID: CGSize], displayID: String) {
        if sizes[displayID] != measured { sizes[displayID] = measured }
    }
}
