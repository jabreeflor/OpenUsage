import Foundation
import Observation

@MainActor
public final class ThresholdSettings: Observable {
    public static let yellowDefaultsKey = "openusage.threshold.yellow"
    public static let redDefaultsKey = "openusage.threshold.red"

    private let _$observationRegistrar = ObservationRegistrar()
    private let defaults: UserDefaults?

    private var _yellowFrom: Int
    private var _redFrom: Int

    public var yellowFrom: Int {
        _$observationRegistrar.access(self, keyPath: \.yellowFrom)
        return _yellowFrom
    }

    public var redFrom: Int {
        _$observationRegistrar.access(self, keyPath: \.redFrom)
        return _redFrom
    }

    public static func isValid(yellow: Int, red: Int) -> Bool {
        yellow > 0 && yellow < red && red <= 100
    }

    /// Creates an isolated in-memory instance starting at the default 50/80 thresholds.
    /// Edits work live for the current session and never read from or persist to `UserDefaults`.
    public static func inMemory() -> ThresholdSettings {
        ThresholdSettings(defaults: nil)
    }

    /// Creates threshold settings appropriate for the launch mode:
    /// demo launches always start with isolated 50/80 in-memory settings regardless of saved live preferences.
    public static func forLaunch(isDemo: Bool, liveDefaults: UserDefaults = .standard) -> ThresholdSettings {
        isDemo ? inMemory() : ThresholdSettings(defaults: liveDefaults)
    }

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let storedYellow = defaults?.object(forKey: Self.yellowDefaultsKey) as? Int
        let storedRed = defaults?.object(forKey: Self.redDefaultsKey) as? Int

        if let y = storedYellow, let r = storedRed, Self.isValid(yellow: y, red: r) {
            self._yellowFrom = y
            self._redFrom = r
        } else {
            self._yellowFrom = DepletionColor.defaultYellowThreshold
            self._redFrom = DepletionColor.defaultRedThreshold
        }
    }

    @discardableResult
    public func update(yellow: Int, red: Int) -> Bool {
        guard Self.isValid(yellow: yellow, red: red) else {
            return false
        }
        _$observationRegistrar.withMutation(of: self, keyPath: \.yellowFrom) {
            _yellowFrom = yellow
        }
        _$observationRegistrar.withMutation(of: self, keyPath: \.redFrom) {
            _redFrom = red
        }
        defaults?.set(yellow, forKey: Self.yellowDefaultsKey)
        defaults?.set(red, forKey: Self.redDefaultsKey)
        return true
    }

    @discardableResult
    public func setYellow(_ yellow: Int) -> Bool {
        update(yellow: yellow, red: _redFrom)
    }

    @discardableResult
    public func setRed(_ red: Int) -> Bool {
        update(yellow: _yellowFrom, red: red)
    }

    public func resetToDefaults() {
        _ = update(
            yellow: DepletionColor.defaultYellowThreshold,
            red: DepletionColor.defaultRedThreshold
        )
    }

    public func level(for percent: Int) -> DepletionLevel {
        DepletionColor.level(percent: percent, yellow: yellowFrom, red: redFrom)
    }
}
