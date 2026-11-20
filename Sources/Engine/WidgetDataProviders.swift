import Cocoa
import Combine
import EventKit
import Darwin

// Data sources for desktop widgets. Each provider only polls while a widget of its kind is placed
// on some wallpaper (see `WidgetDataHub`), so unused widgets cost nothing.

// MARK: - System

public struct SystemSnapshot: Equatable, Sendable {
    public var cpuUsage: Double = 0          // 0...1
    public var memoryUsed: UInt64 = 0
    public var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    public var diskFree: Int64 = 0
    public var diskTotal: Int64 = 0
    public var batteryLevel: Int?
    public var isOnBattery = false
}

@MainActor
public final class SystemStatsProvider: ObservableObject {
    public static let shared = SystemStatsProvider()
    @Published public private(set) var snapshot = SystemSnapshot()

    private var timer: Timer?
    private var previousTicks: (used: UInt64, total: UInt64)?

    public func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 1
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        previousTicks = nil
    }

    private func refresh() {
        var next = snapshot
        if let ticks = Self.cpuTicks() {
            if let previous = previousTicks, ticks.total > previous.total {
                next.cpuUsage = Double(ticks.used - previous.used) / Double(ticks.total - previous.total)
            }
            previousTicks = ticks
        }
        next.memoryUsed = Self.memoryUsed()
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ]) {
            next.diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
            next.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        }
        next.batteryLevel = PowerMonitor.shared.batteryLevel
        next.isOnBattery = PowerMonitor.shared.isOnBattery
        if next != snapshot { snapshot = next }
    }

    private static func cpuTicks() -> (used: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    private static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(getpagesize())
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * pageSize
    }
}

// MARK: - Now Playing (Spotify / Apple Music via AppleScript)

public struct NowPlayingInfo: Equatable, Sendable {
    public var player: String          // "Spotify" or "Music"
    public var title: String
    public var artist: String
    public var isPlaying: Bool
    public var artworkURL: URL?
}

@MainActor
public final class NowPlayingProvider: ObservableObject {
    public static let shared = NowPlayingProvider()
    @Published public private(set) var info: NowPlayingInfo?
    @Published public private(set) var artwork: NSImage?

    private var timer: Timer?
    private var lastArtworkURL: URL?
    private static let players: [(bundleID: String, name: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Music")
    ]

    public func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 1
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Only talks to a player that is already running, so polling never launches one.
    private var runningPlayer: String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.players.first { running.contains($0.bundleID) }?.name
    }

    private func refresh() {
        guard let player = runningPlayer else {
            if info != nil { info = nil; artwork = nil }
            return
        }
        let script: String
        if player == "Spotify" {
            script = """
            tell application "Spotify"
              if player state is stopped then return "stopped"
              set t to current track
              return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (artwork url of t)
            end tell
            """
        } else {
            script = """
            tell application "Music"
              if player state is stopped then return "stopped"
              set t to current track
              return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & ""
            end tell
            """
        }
        Task.detached(priority: .utility) {
            let output = Self.runOSAScript(script)
            await MainActor.run { self.apply(output: output, player: player) }
        }
    }

    private func apply(output: String?, player: String) {
        guard let output, output != "stopped" else {
            if info != nil { info = nil; artwork = nil }
            return
        }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 3 else { return }
        let next = NowPlayingInfo(
            player: player,
            title: parts[1],
            artist: parts[2],
            isPlaying: parts[0] == "playing",
            artworkURL: parts.count > 3 ? URL(string: parts[3]) : nil
        )
        if next != info { info = next }
        loadArtwork(next.artworkURL)
    }

    private func loadArtwork(_ url: URL?) {
        guard url != lastArtworkURL else { return }
        lastArtworkURL = url
        guard let url else {
            artwork = nil
            return
        }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), self.lastArtworkURL == url else { return }
            self.artwork = image
        }
    }

    public func send(_ command: String) {
        guard let player = runningPlayer else { return }
        let script = "tell application \"\(player)\" to \(command)"
        Task.detached(priority: .userInitiated) {
            _ = Self.runOSAScript(script)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run { self.refresh() }
        }
    }

    public func playPause() { send("playpause") }
    public func next() { send("next track") }
    public func previous() { send("previous track") }

    /// Runs AppleScript through `osascript` off the main thread (NSAppleScript is main-thread only).
    private nonisolated static func runOSAScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Weather (Open-Meteo, no API key)

public struct WeatherReport: Equatable, Sendable {
    public var city: String
    public var temperature: Double
    public var high: Double
    public var low: Double
    public var code: Int
    public var fetchedAt: Date

    public var symbolName: String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    public var summary: String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorm"
        default: return "Cloudy"
        }
    }
}

@MainActor
public final class WeatherProvider: ObservableObject {
    public static let shared = WeatherProvider()
    @Published public private(set) var reports: [String: WeatherReport] = [:]
    @Published public private(set) var errors: [String: String] = [:]

    private var cities = Set<String>()
    private var timer: Timer?
    private var inFlight = Set<String>()

    /// Cities currently shown by weather widgets.
    public func setCities(_ newCities: Set<String>) {
        let cleaned = Set(newCities.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let added = cleaned.subtracting(cities)
        cities = cleaned
        if cities.isEmpty {
            timer?.invalidate()
            timer = nil
            return
        }
        if timer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshAll() }
            }
            timer.tolerance = 60
            self.timer = timer
        }
        added.forEach(fetch)
    }

    private func refreshAll() { cities.forEach(fetch) }

    private func fetch(_ city: String) {
        guard !inFlight.contains(city) else { return }
        inFlight.insert(city)
        Task {
            defer { self.inFlight.remove(city) }
            do {
                let report = try await Self.load(city: city)
                self.reports[city] = report
                self.errors[city] = nil
            } catch {
                self.errors[city] = "Couldn't load weather for \(city)"
            }
        }
    }

    private nonisolated static func load(city: String) async throws -> WeatherReport {
        var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geo.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        let (geoData, _) = try await URLSession.shared.data(from: geo.url!)
        struct GeoResponse: Decodable { struct Place: Decodable { let name: String; let latitude: Double; let longitude: Double }; let results: [Place]? }
        guard let place = try JSONDecoder().decode(GeoResponse.self, from: geoData).results?.first else {
            throw URLError(.cannotFindHost)
        }
        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto")
        ]
        let (data, _) = try await URLSession.shared.data(from: forecast.url!)
        struct Forecast: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current
            let daily: Daily
        }
        let decoded = try JSONDecoder().decode(Forecast.self, from: data)
        return WeatherReport(
            city: place.name,
            temperature: decoded.current.temperature_2m,
            high: decoded.daily.temperature_2m_max.first ?? decoded.current.temperature_2m,
            low: decoded.daily.temperature_2m_min.first ?? decoded.current.temperature_2m,
            code: decoded.current.weather_code,
            fetchedAt: Date()
        )
    }
}

// MARK: - Calendar (EventKit)

public struct CalendarEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var isAllDay: Bool
    public var colorHex: String
}

@MainActor
public final class CalendarProvider: ObservableObject {
    public static let shared = CalendarProvider()
    @Published public private(set) var events: [CalendarEntry] = []
    @Published public private(set) var accessDenied = false

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    public func start() {
        guard timer == nil else { return }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.accessDenied = !granted
                if granted { self.refresh() }
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 30
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(4)
            .map { event in
                let color = event.calendar.color.usingColorSpace(.sRGB) ?? .systemBlue
                let hex = String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
                return CalendarEntry(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Event", start: event.startDate, isAllDay: event.isAllDay, colorHex: hex)
            }
    }
}

// MARK: - Hub

/// Starts and stops providers to match the widgets actually placed on wallpapers.
@MainActor
public final class WidgetDataHub {
    public static let shared = WidgetDataHub()
    private var cancellable: AnyCancellable?

    public func start() {
        cancellable = OverlayStore.shared.$configs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configs in self?.sync(configs) }
    }

    private func sync(_ configs: [String: OverlayConfig]) {
        let widgets = configs.values.flatMap(\.widgets)
        let kinds = Set(widgets.map(\.kind))
        kinds.contains(.system) ? SystemStatsProvider.shared.start() : SystemStatsProvider.shared.stop()
        kinds.contains(.nowPlaying) ? NowPlayingProvider.shared.start() : NowPlayingProvider.shared.stop()
        kinds.contains(.calendar) ? CalendarProvider.shared.start() : CalendarProvider.shared.stop()
        WeatherProvider.shared.setCities(Set(widgets.filter { $0.kind == .weather }.map(\.city)))
    }
}
