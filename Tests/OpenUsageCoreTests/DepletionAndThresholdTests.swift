import XCTest
@testable import OpenUsageCore

final class DepletionColorTests: XCTestCase {
    func testDefaultThresholdsBoundaries() {
        XCTAssertEqual(DepletionColor.level(percent: 0), .green)
        XCTAssertEqual(DepletionColor.level(percent: 49), .green)
        XCTAssertEqual(DepletionColor.level(percent: 50), .yellow)
        XCTAssertEqual(DepletionColor.level(percent: 79), .yellow)
        XCTAssertEqual(DepletionColor.level(percent: 80), .red)
        XCTAssertEqual(DepletionColor.level(percent: 100), .red)
    }

    func testCustomThresholdsBoundaries() {
        // Custom thresholds: yellow from 30, red from 60
        XCTAssertEqual(DepletionColor.level(percent: 0, yellow: 30, red: 60), .green)
        XCTAssertEqual(DepletionColor.level(percent: 29, yellow: 30, red: 60), .green)
        XCTAssertEqual(DepletionColor.level(percent: 30, yellow: 30, red: 60), .yellow)
        XCTAssertEqual(DepletionColor.level(percent: 49, yellow: 30, red: 60), .yellow)
        XCTAssertEqual(DepletionColor.level(percent: 50, yellow: 30, red: 60), .yellow)
        XCTAssertEqual(DepletionColor.level(percent: 59, yellow: 30, red: 60), .yellow)
        XCTAssertEqual(DepletionColor.level(percent: 60, yellow: 30, red: 60), .red)
        XCTAssertEqual(DepletionColor.level(percent: 79, yellow: 30, red: 60), .red)
        XCTAssertEqual(DepletionColor.level(percent: 80, yellow: 30, red: 60), .red)
        XCTAssertEqual(DepletionColor.level(percent: 100, yellow: 30, red: 60), .red)

        // Custom thresholds: yellow from 70, red from 95
        XCTAssertEqual(DepletionColor.level(percent: 0, yellow: 70, red: 95), .green)
        XCTAssertEqual(DepletionColor.level(percent: 49, yellow: 70, red: 95), .green)
        XCTAssertEqual(DepletionColor.level(percent: 50, yellow: 70, red: 95), .green)
        XCTAssertEqual(DepletionColor.level(percent: 79, yellow: 70, red: 95), .yellow)
        XCTAssertEqual(DepletionColor.level(percent: 80, yellow: 70, red: 95), .yellow)
        XCTAssertEqual(DepletionColor.level(percent: 94, yellow: 70, red: 95), .yellow)
        XCTAssertEqual(DepletionColor.level(percent: 95, yellow: 70, red: 95), .red)
        XCTAssertEqual(DepletionColor.level(percent: 100, yellow: 70, red: 95), .red)
    }

    func testExactHexColors() {
        XCTAssertEqual(DepletionColor.hex(for: .green), "#4ADE80")
        XCTAssertEqual(DepletionColor.hex(for: .yellow), "#FACC15")
        XCTAssertEqual(DepletionColor.hex(for: .red), "#F87171")
    }
}

@MainActor
final class ThresholdSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "dev.jabree.OpenUsageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsOnFreshSuite() {
        let settings = ThresholdSettings(defaults: defaults)
        XCTAssertEqual(settings.yellowFrom, 50)
        XCTAssertEqual(settings.redFrom, 80)
        XCTAssertEqual(settings.level(for: 49), .green)
        XCTAssertEqual(settings.level(for: 50), .yellow)
        XCTAssertEqual(settings.level(for: 80), .red)
    }

    func testValidUpdateAndPersistence() {
        let settings = ThresholdSettings(defaults: defaults)
        XCTAssertTrue(settings.update(yellow: 40, red: 85))
        XCTAssertEqual(settings.yellowFrom, 40)
        XCTAssertEqual(settings.redFrom, 85)
        XCTAssertEqual(settings.level(for: 40), .yellow)
        XCTAssertEqual(settings.level(for: 84), .yellow)
        XCTAssertEqual(settings.level(for: 85), .red)

        let reloaded = ThresholdSettings(defaults: defaults)
        XCTAssertEqual(reloaded.yellowFrom, 40)
        XCTAssertEqual(reloaded.redFrom, 85)
    }

    func testValidationRejectsInvalidRanges() {
        let settings = ThresholdSettings(defaults: defaults)

        XCTAssertFalse(ThresholdSettings.isValid(yellow: 0, red: 80))
        XCTAssertFalse(ThresholdSettings.isValid(yellow: -10, red: 80))
        XCTAssertFalse(ThresholdSettings.isValid(yellow: 80, red: 80))
        XCTAssertFalse(ThresholdSettings.isValid(yellow: 85, red: 80))
        XCTAssertFalse(ThresholdSettings.isValid(yellow: 50, red: 101))
        XCTAssertTrue(ThresholdSettings.isValid(yellow: 1, red: 100))

        XCTAssertFalse(settings.update(yellow: 0, red: 80))
        XCTAssertFalse(settings.update(yellow: 80, red: 80))
        XCTAssertFalse(settings.update(yellow: 90, red: 80))
        XCTAssertFalse(settings.update(yellow: 50, red: 101))
        XCTAssertFalse(settings.setYellow(80))
        XCTAssertFalse(settings.setRed(50))

        // Existing valid values remain intact
        XCTAssertEqual(settings.yellowFrom, 50)
        XCTAssertEqual(settings.redFrom, 80)
    }

    func testCorruptedDefaultsFallbackToValidDefaults() {
        defaults.set(90, forKey: ThresholdSettings.yellowDefaultsKey)
        defaults.set(70, forKey: ThresholdSettings.redDefaultsKey)

        let settings = ThresholdSettings(defaults: defaults)
        XCTAssertEqual(settings.yellowFrom, 50)
        XCTAssertEqual(settings.redFrom, 80)
    }

    func testResetToDefaults() {
        let settings = ThresholdSettings(defaults: defaults)
        XCTAssertTrue(settings.update(yellow: 35, red: 75))
        settings.resetToDefaults()
        XCTAssertEqual(settings.yellowFrom, 50)
        XCTAssertEqual(settings.redFrom, 80)
    }

    func testDemoThresholdsAreIsolatedFromSavedLivePreferences() {
        // Persist custom live thresholds first
        let live = ThresholdSettings.forLaunch(isDemo: false, liveDefaults: defaults)
        XCTAssertTrue(live.update(yellow: 30, red: 60))
        XCTAssertEqual(live.yellowFrom, 30)
        XCTAssertEqual(live.redFrom, 60)

        // Demo launch must ignore saved live thresholds and start at 50/80
        let demo = ThresholdSettings.forLaunch(isDemo: true, liveDefaults: defaults)
        XCTAssertEqual(demo.yellowFrom, 50)
        XCTAssertEqual(demo.redFrom, 80)
        XCTAssertEqual(demo.level(for: 49), .green)
        XCTAssertEqual(demo.level(for: 50), .yellow)
        XCTAssertEqual(demo.level(for: 79), .yellow)
        XCTAssertEqual(demo.level(for: 80), .red)

        // Edits during a demo session still work live
        XCTAssertTrue(demo.update(yellow: 25, red: 70))
        XCTAssertEqual(demo.yellowFrom, 25)
        XCTAssertEqual(demo.redFrom, 70)
        XCTAssertEqual(demo.level(for: 25), .yellow)
        XCTAssertEqual(demo.level(for: 70), .red)

        // Demo edits must never overwrite the live suite
        let liveReloaded = ThresholdSettings.forLaunch(isDemo: false, liveDefaults: defaults)
        XCTAssertEqual(liveReloaded.yellowFrom, 30)
        XCTAssertEqual(liveReloaded.redFrom, 60)

        // Subsequent demo launches still start fresh at 50/80
        let nextDemo = ThresholdSettings.forLaunch(isDemo: true, liveDefaults: defaults)
        XCTAssertEqual(nextDemo.yellowFrom, 50)
        XCTAssertEqual(nextDemo.redFrom, 80)
    }

    func testStringInputParsingAndEditingValidation() {
        let settings = ThresholdSettings(defaults: defaults)

        // Raising red threshold to 90 turns Claude's 81% from red to yellow
        XCTAssertEqual(settings.level(for: 81), .red)
        XCTAssertTrue(settings.applyRedInput("90"))
        XCTAssertEqual(settings.redFrom, 90)
        XCTAssertEqual(settings.level(for: 81), .yellow)
        XCTAssertEqual(settings.level(for: 90), .red)

        // Accepts trailing % and surrounding whitespace
        XCTAssertTrue(settings.applyYellowInput(" 40% "))
        XCTAssertEqual(settings.yellowFrom, 40)
        XCTAssertTrue(settings.applyRedInput("85%"))
        XCTAssertEqual(settings.redFrom, 85)

        // Rejects non-numeric, empty, negative, decimal, out-of-range, and inverted values
        for invalid in ["", "   ", "abc", "-5", "40.5", "0", "85", "90", "101", "50%%"] {
            XCTAssertFalse(settings.applyYellowInput(invalid), "Expected yellow input '\(invalid)' to be rejected")
        }
        for invalid in ["", "   ", "xyz", "-1", "85.2", "0", "40", "35", "101", "90px"] {
            XCTAssertFalse(settings.applyRedInput(invalid), "Expected red input '\(invalid)' to be rejected")
        }

        // Previous valid thresholds remain intact
        XCTAssertEqual(settings.yellowFrom, 40)
        XCTAssertEqual(settings.redFrom, 85)
    }
}
