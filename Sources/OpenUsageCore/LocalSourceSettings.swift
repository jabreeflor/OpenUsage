import Foundation
import Observation

/// Local log/token sources shown under "Count tokens from local tools" in Accounts.
public enum LocalToolSource: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case claudeCode = "claude_code"
    case codexCLI = "codex_cli"
    case geminiCLI = "gemini_cli"
    case openCode = "opencode"
    case cursor = "cursor"

    public var id: String { rawValue }

    public var provider: ProviderID {
        switch self {
        case .claudeCode: .claude
        case .codexCLI: .chatgpt
        case .geminiCLI: .gemini
        case .openCode: .opencode
        case .cursor: .cursor
        }
    }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codexCLI: "Codex CLI"
        case .geminiCLI: "Gemini CLI"
        case .openCode: "OpenCode"
        case .cursor: "Cursor"
        }
    }

    public var pathLabel: String {
        switch self {
        case .claudeCode: "~/.claude/projects"
        case .codexCLI: "~/.codex/sessions"
        case .geminiCLI: "~/.gemini/tmp"
        case .openCode: "~/.local/share/opencode"
        case .cursor: "from your Cursor account"
        }
    }

    /// Default enabled state matching `FinalAccounts.dc.html` and still 06.
    public var defaultEnabled: Bool {
        switch self {
        case .claudeCode, .codexCLI, .geminiCLI, .cursor:
            true
        case .openCode:
            false
        }
    }

    public var defaultsKey: String {
        "openusage.localSource.\(rawValue)"
    }
}

@MainActor
public final class LocalSourceSettings: Observable {
    private let _$observationRegistrar = ObservationRegistrar()
    private let defaults: UserDefaults?
    private var _enabledSources: [LocalToolSource: Bool]

    public var enabledSources: [LocalToolSource: Bool] {
        _$observationRegistrar.access(self, keyPath: \.enabledSources)
        return _enabledSources
    }

    public static func defaultMap(for scenario: DemoScenario? = nil) -> [LocalToolSource: Bool] {
        var map: [LocalToolSource: Bool] = [:]
        for source in LocalToolSource.allCases {
            switch scenario {
            case .all:
                map[source] = true
            case .connecting, .disconnected, nil:
                map[source] = source.defaultEnabled
            }
        }
        return map
    }

    /// Volatile in-memory settings for demo launches and tests; never touches `UserDefaults`.
    public static func inMemory(demoScenario: DemoScenario? = nil) -> LocalSourceSettings {
        LocalSourceSettings(defaults: nil, initialValues: defaultMap(for: demoScenario))
    }

    /// Creates local-source settings for the current launch mode.
    /// Demo launches start volatile with fixture defaults and never read or write live preferences.
    public static func forLaunch(
        isDemo: Bool,
        demoScenario: DemoScenario = .all,
        liveDefaults: UserDefaults = .standard
    ) -> LocalSourceSettings {
        if isDemo {
            return inMemory(demoScenario: demoScenario)
        }
        return LocalSourceSettings(defaults: liveDefaults)
    }

    public init(defaults: UserDefaults? = .standard, initialValues: [LocalToolSource: Bool]? = nil) {
        self.defaults = defaults
        var resolved = initialValues ?? Self.defaultMap()
        if let defaults {
            for source in LocalToolSource.allCases {
                if defaults.object(forKey: source.defaultsKey) != nil {
                    resolved[source] = defaults.bool(forKey: source.defaultsKey)
                }
            }
        }
        self._enabledSources = resolved
    }

    public func isEnabled(_ source: LocalToolSource) -> Bool {
        enabledSources[source] ?? source.defaultEnabled
    }

    public func setEnabled(_ enabled: Bool, for source: LocalToolSource) {
        guard _enabledSources[source] != enabled else { return }
        _$observationRegistrar.withMutation(of: self, keyPath: \.enabledSources) {
            _enabledSources[source] = enabled
        }
        defaults?.set(enabled, forKey: source.defaultsKey)
    }

    public func toggle(_ source: LocalToolSource) {
        setEnabled(!isEnabled(source), for: source)
    }
}
