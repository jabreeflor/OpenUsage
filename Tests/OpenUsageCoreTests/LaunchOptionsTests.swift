import XCTest
@testable import OpenUsageCore

final class LaunchOptionsTests: XCTestCase {
    func testDefaultOptions() {
        let options = LaunchOptions.parse(arguments: ["OpenUsage"], environment: [:])
        XCTAssertFalse(options.isDemo)
        XCTAssertEqual(options.demoScenario, .all)
        XCTAssertNil(options.openScreen)
        XCTAssertNil(options.selectedProvider)
        XCTAssertNil(options.snapshotDir)
        XCTAssertFalse(options.printWindowFrames)
        XCTAssertFalse(options.dumpTokenSummary)
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
        XCTAssertNil(options.selectedProvider)
        XCTAssertNil(options.snapshotDir)
        XCTAssertFalse(options.printWindowFrames)
        XCTAssertFalse(options.dumpTokenSummary)
    }

    func testSelectProviderFlag() {
        let spaceSyntax = LaunchOptions.parse(
            arguments: ["OpenUsage", "--open", "dropdown", "--select", "cursor"],
            environment: [:]
        )
        XCTAssertEqual(spaceSyntax.openScreen, .dropdown)
        XCTAssertEqual(spaceSyntax.selectedProvider, .cursor)

        let equalsSyntax = LaunchOptions.parse(
            arguments: ["OpenUsage", "--select=OpenCode"],
            environment: [:]
        )
        XCTAssertEqual(equalsSyntax.selectedProvider, .opencode)

        let invalid = LaunchOptions.parse(
            arguments: ["OpenUsage", "--select", "unknown"],
            environment: [:]
        )
        XCTAssertNil(invalid.selectedProvider)
        XCTAssertEqual(invalid.statisticsFilter, .overview)
    }

    func testStatisticsRangeAndSelectOverviewFlags() {
        let defaults = LaunchOptions.parse(arguments: ["OpenUsage"], environment: [:])
        XCTAssertEqual(defaults.statisticsRange, .thirtyDays)
        XCTAssertEqual(defaults.statisticsFilter, .overview)

        let claude7d = LaunchOptions.parse(
            arguments: ["OpenUsage", "--open", "statistics", "--select", "claude", "--range", "7d"],
            environment: [:]
        )
        XCTAssertEqual(claude7d.openScreen, .statistics)
        XCTAssertEqual(claude7d.selectedProvider, .claude)
        XCTAssertEqual(claude7d.statisticsFilter, .provider(.claude))
        XCTAssertEqual(claude7d.statisticsRange, .sevenDays)

        let overview30d = LaunchOptions.parse(
            arguments: ["OpenUsage", "--select=claude", "--select=overview", "--range=30D"],
            environment: [:]
        )
        XCTAssertNil(overview30d.selectedProvider)
        XCTAssertEqual(overview30d.statisticsFilter, .overview)
        XCTAssertEqual(overview30d.statisticsRange, .thirtyDays)

        let invalidRange = LaunchOptions.parse(
            arguments: ["OpenUsage", "--range", "90d"],
            environment: [:]
        )
        XCTAssertEqual(invalidRange.statisticsRange, .thirtyDays)
    }

    func testPrintWindowFramesFlag() {
        let parsed = LaunchOptions.parse(
            arguments: ["OpenUsage", "--demo", "--open", "statistics", "--print-window-frames"],
            environment: [:]
        )
        XCTAssertTrue(parsed.isDemo)
        XCTAssertEqual(parsed.openScreen, .statistics)
        XCTAssertTrue(parsed.printWindowFrames)
        XCTAssertFalse(parsed.dumpTokenSummary)
    }

    func testDumpTokenSummaryFlag() {
        let parsed = LaunchOptions.parse(
            arguments: ["OpenUsage", "--dump-token-summary"],
            environment: [:]
        )
        XCTAssertFalse(parsed.isDemo)
        XCTAssertTrue(parsed.dumpTokenSummary)

        let demoDump = LaunchOptions.parse(
            arguments: ["OpenUsage", "--demo", "--dump-token-summary"],
            environment: [:]
        )
        XCTAssertTrue(demoDump.isDemo)
        XCTAssertTrue(demoDump.dumpTokenSummary)
    }
}
