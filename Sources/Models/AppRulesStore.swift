import Foundation
import Combine
import AppKit

public enum AppRuleCondition: String, Codable, CaseIterable, Sendable {
    case whenFocused
    case whenRunning
    case whenFullscreen

    public var displayName: String {
        switch self {
        case .whenFocused: return "When Focused"
        case .whenRunning: return "When Running"
        case .whenFullscreen: return "When Fullscreen"
        }
    }
}

public enum AppRuleAction: String, Codable, CaseIterable, Sendable {
    case pause
    case stopAndFreeRAM
    case muteAudio
    case keepRunning

    public var displayName: String {
        switch self {
        case .pause: return "Pause"
        case .stopAndFreeRAM: return "Stop (Free RAM)"
        case .muteAudio: return "Mute Audio"
        case .keepRunning: return "Keep Running"
        }
    }

    public var symbolName: String {
        switch self {
        case .pause: return "pause.circle"
        case .stopAndFreeRAM: return "memorychip"
        case .muteAudio: return "speaker.slash"
        case .keepRunning: return "play.circle"
        }
    }
}

public struct AppRule: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var appName: String
    public var bundleIdentifier: String
    public var condition: AppRuleCondition
    public var action: AppRuleAction
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        appName: String,
        bundleIdentifier: String,
        condition: AppRuleCondition = .whenFocused,
        action: AppRuleAction = .pause,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.condition = condition
        self.action = action
        self.isEnabled = isEnabled
    }
}

public struct AppRuleEvaluation: Equatable, Sendable {
    public let matchedRule: AppRule
    public let action: AppRuleAction

    public var reasonLabel: String {
        "\(matchedRule.appName) Rule (\(action.displayName))"
    }
}

@MainActor
public class AppRulesStore: ObservableObject {
    public static let shared = AppRulesStore()

    @Published public var rules: [AppRule] = [] {
        didSet {
            saveRules()
        }
    }

    private let storageKey = "nimbscape.appRules.v1"

    private init() {
        loadRules()
    }

    private func loadRules() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AppRule].self, from: data) {
            self.rules = decoded
            return
        }

        self.rules = [
            AppRule(
                id: "default-xcode",
                appName: "Xcode",
                bundleIdentifier: "com.apple.dt.Xcode",
                condition: .whenFocused,
                action: .pause,
                isEnabled: false
            ),
            AppRule(
                id: "default-fcp",
                appName: "Final Cut Pro",
                bundleIdentifier: "com.apple.FinalCut",
                condition: .whenRunning,
                action: .stopAndFreeRAM,
                isEnabled: false
            ),
            AppRule(
                id: "default-spotify",
                appName: "Spotify",
                bundleIdentifier: "com.spotify.client",
                condition: .whenRunning,
                action: .muteAudio,
                isEnabled: false
            )
        ]
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    public func addRule(_ rule: AppRule) {
        if let idx = rules.firstIndex(where: { $0.bundleIdentifier == rule.bundleIdentifier && $0.condition == rule.condition }) {
            rules[idx] = rule
        } else {
            rules.append(rule)
        }
    }

    public func updateRule(_ rule: AppRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        }
    }

    public func removeRule(id: String) {
        rules.removeAll(where: { $0.id == id })
    }

    public func toggleRule(id: String) {
        if let idx = rules.firstIndex(where: { $0.id == id }) {
            rules[idx].isEnabled.toggle()
        }
    }

    public static func makeRule(fromAppURL url: URL, condition: AppRuleCondition = .whenFocused, action: AppRuleAction = .pause) -> AppRule? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return nil
        }
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppRule(
            appName: appName,
            bundleIdentifier: bundleID,
            condition: condition,
            action: action,
            isEnabled: true
        )
    }

    public func evaluate(
        frontmostBundleID: String?,
        runningBundleIDs: Set<String>,
        fullscreenBundleIDs: Set<String>
    ) -> AppRuleEvaluation? {
        let matched = rules.filter { rule in
            guard rule.isEnabled else { return false }
            switch rule.condition {
            case .whenFocused:
                return frontmostBundleID == rule.bundleIdentifier
            case .whenRunning:
                return runningBundleIDs.contains(rule.bundleIdentifier)
            case .whenFullscreen:
                return fullscreenBundleIDs.contains(rule.bundleIdentifier)
            }
        }

        guard !matched.isEmpty else { return nil }

        let priority: [AppRuleAction] = [.stopAndFreeRAM, .pause, .muteAudio, .keepRunning]
        for action in priority {
            if let rule = matched.first(where: { $0.action == action }) {
                return AppRuleEvaluation(matchedRule: rule, action: action)
            }
        }
        return nil
    }
}
