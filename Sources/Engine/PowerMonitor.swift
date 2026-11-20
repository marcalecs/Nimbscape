import Cocoa
import Combine
import IOKit.ps

public struct PowerPolicyState: Equatable, Sendable {
    public var shouldPause: Bool
    public var shouldStopAndFreeRAM: Bool
    public var shouldMuteAudio: Bool
    public var isHardwareSleepOrLock: Bool
    public var pauseReason: String?
    /// Displays (by `stableDisplayID`) paused because a window covers them while other displays keep
    /// playing. Empty when nothing is covered or when the whole desktop is paused (`shouldPause`).
    public var pausedDisplayIDs: Set<String> = []
    /// True when the whole desktop is paused only because windows cover every display. Such a pause
    /// may be lifted early the moment a wallpaper window becomes visible (e.g. mid Space swipe).
    public var isWindowCoverPause: Bool = false

    public static let running = PowerPolicyState(
        shouldPause: false,
        shouldStopAndFreeRAM: false,
        shouldMuteAudio: false,
        isHardwareSleepOrLock: false,
        pauseReason: nil
    )
}

/// Windows found on each display by the occlusion scan, keyed by `NSScreen.stableDisplayID`.
private struct WindowScan {
    var fullscreenBundleIDs = Set<String>()
    var fullscreenDisplays = Set<String>()
    var maximizedDisplays = Set<String>()
    var anyWindowDisplays = Set<String>()
    var ownerNameByDisplay: [String: String] = [:]
}

@MainActor
public protocol PowerMonitorDelegate: AnyObject {
    func powerMonitorDidUpdatePolicy(_ state: PowerPolicyState)
    func powerMonitorDidUnlockOrWake()
    /// Called after the post-Space-switch evaluation ran, whether or not the policy changed.
    func powerMonitorDidSettleAfterSpaceChange()
}

@MainActor
public class PowerMonitor: ObservableObject {
    public static let shared = PowerMonitor()

    public weak var delegate: PowerMonitorDelegate?

    @Published public private(set) var powerPauseReason: String? = nil
    @Published public var overrideSystemPause: Bool = false {
        didSet {
            evaluateState()
        }
    }
    @Published public private(set) var isOnBattery: Bool = false
    @Published public private(set) var batteryLevel: Int? = nil
    @Published public private(set) var isLowPowerMode: Bool = false

    /// True when wallpapers should run at a reduced frame rate (30 FPS) to save energy.
    public var isLowPowerThrottled: Bool {
        AppPreferences.shared.pauseOnLowPowerMode && isLowPowerMode
    }
    @Published public private(set) var isSystemPaused: Bool = false
    @Published public private(set) var isStoppedToFreeRAM: Bool = false
    @Published public private(set) var isRuleMuted: Bool = false
    @Published public private(set) var activeRuleMatch: AppRuleEvaluation? = nil

    private var isSystemSleeping: Bool = false
    private var isScreenSleeping: Bool = false
    private var isScreenLocked: Bool = false
    private var lastPolicy: PowerPolicyState = .running
    private var checkTimer: Timer?
    private var timerTickCount: Int = 0

    /// After a Space switch the window scan and any pause/resume wait until the swipe animation
    /// has settled, then run once. Changing playback mid-swipe made the gesture stutter.
    private static let spaceSettleDelay: TimeInterval = 0.6
    private var spaceSettleDeadline: Date = .distantPast
    private var deferredEvaluation: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        refreshBatteryTelemetry()
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        setupNotifications()
        setupBindings()
        startPeriodicChecks()
    }

    private func setupNotifications() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWillSleep() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDidWake() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreensDidSleep() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreensDidWake() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSessionResign() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSessionActive() }
        }

        workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleActiveSpaceChange() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }
        nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }
        nc.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWorkspaceAppChange() }
        }

        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenLocked() }
        }
        distributedCenter.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenUnlocked() }
        }

        nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handlePowerStateDidChange() }
        }
    }

    private func setupBindings() {
        AppRulesStore.shared.$rules
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluateState() }
            .store(in: &cancellables)

        let preferences = AppPreferences.shared
        Publishers.CombineLatest4(
            preferences.$pauseOnBattery,
            preferences.$pauseOnLowPowerMode,
            preferences.$pauseOnFullscreen,
            preferences.$pauseOnMaximized
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in self?.evaluateState() }
        .store(in: &cancellables)

        preferences.$windowPauseMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluateState() }
            .store(in: &cancellables)

        preferences.$pauseOnBatteryBelowPercent
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluateState() }
            .store(in: &cancellables)
    }

    private func startPeriodicChecks() {
        let timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.timerTickCount += 1
                if self.timerTickCount % 6 == 0 {
                    self.refreshBatteryTelemetry()
                }
                // A deferred evaluation is already queued for the end of a Space switch.
                guard !self.isSettlingAfterSpaceChange else { return }
                self.evaluateState()
            }
        }
        timer.tolerance = 1.0
        checkTimer = timer
    }

    private func handleWillSleep() {
        isSystemSleeping = true
        evaluateState()
    }

    private func handleDidWake() {
        isSystemSleeping = false
        isScreenSleeping = false
        refreshBatteryTelemetry()
        evaluateState()
        delegate?.powerMonitorDidUnlockOrWake()
    }

    private func handleScreensDidSleep() {
        isScreenSleeping = true
        evaluateState()
    }

    private func handleScreensDidWake() {
        isScreenSleeping = false
        refreshBatteryTelemetry()
        evaluateState()
        delegate?.powerMonitorDidUnlockOrWake()
    }

    private func handleScreenLocked() {
        isScreenLocked = true
        evaluateState()
    }

    private func handleScreenUnlocked() {
        isScreenLocked = false
        isScreenSleeping = false
        isSystemSleeping = false
        refreshBatteryTelemetry()
        evaluateState()
        delegate?.powerMonitorDidUnlockOrWake()
    }

    private func handleSessionResign() {
        isScreenLocked = true
        evaluateState()
    }

    private func handleSessionActive() {
        isScreenLocked = false
        refreshBatteryTelemetry()
        evaluateState()
        delegate?.powerMonitorDidUnlockOrWake()
    }

    private func handleWorkspaceAppChange() {
        if isSettlingAfterSpaceChange {
            scheduleDeferredEvaluation()
            return
        }
        evaluateState()
    }

    private func handleActiveSpaceChange() {
        spaceSettleDeadline = Date().addingTimeInterval(Self.spaceSettleDelay)
        scheduleDeferredEvaluation()
    }

    /// True while a Space-switch animation may still be running.
    public var isSettlingAfterSpaceChange: Bool {
        Date() < spaceSettleDeadline
    }

    /// Coalesces every evaluation requested during the settle window into one at its end.
    private func scheduleDeferredEvaluation() {
        deferredEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluateState()
                self?.delegate?.powerMonitorDidSettleAfterSpaceChange()
            }
        }
        deferredEvaluation = work
        let delay = max(0, spaceSettleDeadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handlePowerStateDidChange() {
        self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        self.refreshBatteryTelemetry()
        self.evaluateState()
    }

    public func refreshBatteryTelemetry() {
        var onBattery = false
        var level: Int? = nil

        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in sources {
                guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else {
                    continue
                }
                if let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                    if state == (kIOPSBatteryPowerValue as String) {
                        onBattery = true
                    }
                }
                if let cap = desc[kIOPSCurrentCapacityKey as String] as? Int {
                    let maxCap = (desc[kIOPSMaxCapacityKey as String] as? Int) ?? 100
                    level = CoreRules.batteryPercent(current: cap, max: maxCap)
                }
            }
        }

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if self.isOnBattery != onBattery { self.isOnBattery = onBattery }
        if self.batteryLevel != level { self.batteryLevel = level }
        if self.isLowPowerMode != lowPower { self.isLowPowerMode = lowPower }
    }

    private func inspectOnScreenWindows() -> WindowScan {
        let ownBundleID = Bundle.main.bundleIdentifier
        let ignoredSystemBundles: Set<String> = [
            "com.apple.dock",
            "com.apple.WindowManager",
            "com.apple.WindowServer",
            "com.apple.wallpaper.agent",
            "com.apple.loginwindow",
            "com.apple.controlcenter",
            "com.apple.controlstrip",
            "com.apple.notificationcenterui",
            "com.apple.Spotlight",
            "com.apple.systemuiserver",
            "com.apple.TextInputMenuAgent",
            "com.apple.screencaptureui",
            "com.apple.CoreServicesUIAgent"
        ]

        let runningApps = NSWorkspace.shared.runningApplications
        var bundleByPID: [pid_t: String] = [:]
        for app in runningApps {
            if let bundleIdentifier = app.bundleIdentifier {
                bundleByPID[app.processIdentifier] = bundleIdentifier
            }
        }

        let screens = NSScreen.screens
        var scan = WindowScan()

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return scan
        }

        for info in windowList {
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }

            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard alpha > 0.05 else { continue }

            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bundleID = bundleByPID[pid] else { continue }

            if ignoredSystemBundles.contains(bundleID) {
                continue
            }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

            guard bounds.width > 200 && bounds.height > 200 else { continue }

            if bundleID == "com.apple.finder" {
                let winName = (info[kCGWindowName as String] as? String) ?? ""
                if winName.isEmpty, screens.contains(where: { abs(bounds.width - $0.frame.width) <= 4 && abs(bounds.height - $0.frame.height) <= 4 }) {
                    continue
                }
            }

            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? bundleID
            guard let screen = Self.screen(containing: bounds, in: screens) else { continue }
            let displayID = screen.stableDisplayID
            var windowIsMaximized = false

            if abs(bounds.width - screen.frame.width) <= 6 && abs(bounds.height - screen.frame.height) <= 6 {
                scan.fullscreenBundleIDs.insert(bundleID)
                scan.fullscreenDisplays.insert(displayID)
                windowIsMaximized = true
            }

            let visibleArea = max(1, screen.visibleFrame.width * screen.visibleFrame.height)
            let coveredArea = Self.cgRect(of: screen).intersection(bounds)
            if !coveredArea.isNull, (coveredArea.width * coveredArea.height) / visibleArea >= 0.75 {
                scan.maximizedDisplays.insert(displayID)
                windowIsMaximized = true
            }

            if bundleID != ownBundleID || windowIsMaximized {
                scan.anyWindowDisplays.insert(displayID)
                if scan.ownerNameByDisplay[displayID] == nil {
                    scan.ownerNameByDisplay[displayID] = ownerName
                }
            }
        }

        return scan
    }

    /// Screen frame in CoreGraphics window coordinates (origin top-left of the primary display).
    private static func cgRect(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    /// The screen a window (in CG coordinates) mostly sits on.
    private static func screen(containing windowBounds: CGRect, in screens: [NSScreen]) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in screens {
            let overlap = cgRect(of: screen).intersection(windowBounds)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (screen, area) }
        }
        return best?.screen
    }

    public func evaluateState() {
        let preferences = AppPreferences.shared

        if isSystemSleeping || isScreenSleeping || isScreenLocked {
            let reason = isScreenLocked ? "Screen Locked" : (isSystemSleeping ? "System Sleep" : "Display Sleep")
            applyPolicy(
                PowerPolicyState(
                    shouldPause: true,
                    shouldStopAndFreeRAM: false,
                    shouldMuteAudio: false,
                    isHardwareSleepOrLock: true,
                    pauseReason: reason
                ),
                ruleMatch: nil
            )
            return
        }

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let windowScan = inspectOnScreenWindows()

        let ruleEval = AppRulesStore.shared.evaluate(
            frontmostBundleID: frontmostBundleID,
            runningBundleIDs: runningBundleIDs,
            fullscreenBundleIDs: windowScan.fullscreenBundleIDs
        )

        if let eval = ruleEval {
            switch eval.action {
            case .stopAndFreeRAM:
                applyPolicy(
                    PowerPolicyState(
                        shouldPause: true,
                        shouldStopAndFreeRAM: true,
                        shouldMuteAudio: false,
                        isHardwareSleepOrLock: false,
                        pauseReason: "\(eval.matchedRule.appName) Rule"
                    ),
                    ruleMatch: eval
                )
                return
            case .pause:
                applyPolicy(
                    PowerPolicyState(
                        shouldPause: true,
                        shouldStopAndFreeRAM: false,
                        shouldMuteAudio: false,
                        isHardwareSleepOrLock: false,
                        pauseReason: "\(eval.matchedRule.appName) Rule"
                    ),
                    ruleMatch: eval
                )
                return
            case .muteAudio:
                break
            case .keepRunning:
                applyPolicy(.running, ruleMatch: eval)
                return
            }
        }

        let ruleMutesAudio = (ruleEval?.action == .muteAudio)

        // Window-based pauses are decided per display: only displays a window covers pause, the
        // others keep playing. If every display is covered, the whole desktop pauses as before.
        let coveredDisplays: Set<String>
        let coverLabel: String
        switch preferences.windowPauseMode {
        case .anyWindow:
            coveredDisplays = windowScan.anyWindowDisplays.union(windowScan.fullscreenDisplays)
            coverLabel = "Window Open"
        case .maximizedOrFullscreen:
            coveredDisplays = windowScan.maximizedDisplays.union(windowScan.fullscreenDisplays)
            coverLabel = windowScan.fullscreenDisplays.isEmpty ? "Maximized Window" : "Fullscreen App"
        case .fullscreenOnly:
            coveredDisplays = windowScan.fullscreenDisplays
            coverLabel = "Fullscreen App"
        case .never:
            coveredDisplays = []
            coverLabel = ""
        }

        let allDisplays = Set(NSScreen.screens.map { $0.stableDisplayID })
        if !coveredDisplays.isEmpty && allDisplays.isSubset(of: coveredDisplays) {
            var label = coverLabel
            if preferences.windowPauseMode == .anyWindow, allDisplays.count == 1,
               let owner = windowScan.ownerNameByDisplay.values.first {
                label = "\(owner) Open"
            }
            applyPolicy(
                PowerPolicyState(
                    shouldPause: true,
                    shouldStopAndFreeRAM: false,
                    shouldMuteAudio: ruleMutesAudio,
                    isHardwareSleepOrLock: false,
                    pauseReason: label,
                    isWindowCoverPause: true
                ),
                ruleMatch: ruleEval
            )
            return
        }
        let partiallyPausedDisplays = coveredDisplays.intersection(allDisplays)

        if !overrideSystemPause {
            // Low Power Mode no longer pauses: WallpaperManager caps playback at 30 FPS instead
            // (see `isLowPowerThrottled`).

            if preferences.pauseOnBattery && isOnBattery
                && (batteryLevel ?? 0) <= preferences.pauseOnBatteryBelowPercent {
                applyPolicy(
                    PowerPolicyState(
                        shouldPause: true,
                        shouldStopAndFreeRAM: false,
                        shouldMuteAudio: ruleMutesAudio,
                        isHardwareSleepOrLock: false,
                        pauseReason: "Battery Below \(preferences.pauseOnBatteryBelowPercent)%"
                    ),
                    ruleMatch: ruleEval
                )
                return
            }
        }

        applyPolicy(
            PowerPolicyState(
                shouldPause: false,
                shouldStopAndFreeRAM: false,
                shouldMuteAudio: ruleMutesAudio,
                isHardwareSleepOrLock: false,
                pauseReason: partiallyPausedDisplays.isEmpty
                    ? nil
                    : "\(coverLabel) · \(partiallyPausedDisplays.count) of \(allDisplays.count) Displays Paused",
                pausedDisplayIDs: partiallyPausedDisplays
            ),
            ruleMatch: ruleEval
        )
    }

    private func applyPolicy(_ policy: PowerPolicyState, ruleMatch: AppRuleEvaluation?) {
        let changed = (policy != lastPolicy) || (ruleMatch != activeRuleMatch)
        lastPolicy = policy

        self.powerPauseReason = policy.pauseReason
        self.isSystemPaused = policy.shouldPause
        self.isStoppedToFreeRAM = policy.shouldStopAndFreeRAM
        self.isRuleMuted = policy.shouldMuteAudio
        self.activeRuleMatch = ruleMatch
        if changed {
            self.delegate?.powerMonitorDidUpdatePolicy(policy)
        }
    }
}

