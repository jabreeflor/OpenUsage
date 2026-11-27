import XCTest
@testable import OpenUsageCore

final class LaunchOptionsTests: XCTestCase {
    func testDefaultOptions() {
        let options = LaunchOptions.parse(arguments: ["OpenUsage"], environment: [:])
        XCTAssertFalse(options.isDemo)
        XCTAssertEqual(options.demoScenario, .all)
        XCTAssertNil(options.openScreen)
        XCTAssertNil(options.snapshotDir)
    }

    func testDemoFlagAndEnvironmentVariable() {
        let byFlag = LaunchOptions.parse(arguments: ["OpenUsage", "--demo"], environment: [:])
        XCTAssertTrue(byFlag.isDemo)

        let byEnv1 = LaunchOptions.parse(arguments: ["OpenUsage"], environment: ["OPENUSAGE_DEMO": "1"])
        XCTAssertTrue(byEnv1.isDemo)

        let byEnvTrue = LaunchOptions.parse(arguments: ["OpenUsage"], environment: ["OPENUSAGE_DEMO": "true"])
        XCTAssertTrue(byEnvTrue.isDemo)

        let byEnvZero = LaunchOptions.parse(arguments: ["OpenUsage"], environment: ["OPENUSAGE_DEMO": "0"])
        XCTAssertFalse(byEnvZero.isDemo)
    }

    func testAllFlagsSpaceSeparated() {
        let options = LaunchOptions.parse(
            arguments: [
                "OpenUsage",
                "--demo",
                "--demo-scenario", "disconnected",
                "--open", "accounts",
                "--snapshot-dir", "/tmp/openusage-snaps"
            ],
            environment: [:]
        )
        XCTAssertTrue(options.isDemo)
        XCTAssertEqual(options.demoScenario, .disconnected)
        XCTAssertEqual(options.openScreen, .accounts)
        XCTAssertEqual(options.snapshotDir?.path, "/tmp/openusage-snaps")
    }

    func testAllFlagsEqualsSyntax() {
        let options = LaunchOptions.parse(
            arguments: [
                "OpenUsage",
                "--demo-scenario=connecting",
                "--open=statistics",
                "--snapshot-dir=/tmp/snaps2"
            ],
            environment: ["OPENUSAGE_DEMO": "1"]
        )
        XCTAssertTrue(options.isDemo)
        XCTAssertEqual(options.demoScenario, .connecting)
        XCTAssertEqual(options.openScreen, .statistics)
        XCTAssertEqual(options.snapshotDir?.path, "/tmp/snaps2")
    }

    func testOpenDropdownAndUnknownValuesIgnored() {
        let options = LaunchOptions.parse(
            arguments: [
                "OpenUsage",
                "--demo-scenario", "bogus",
                "--open", "dropdown",
                "--unknown-flag"
            ],
            environment: [:]
        )
        XCTAssertFalse(options.isDemo)
        XCTAssertEqual(options.demoScenario, .all)
        XCTAssertEqual(options.openScreen, .dropdown)
        XCTAssertNil(options.snapshotDir)
    }
}
