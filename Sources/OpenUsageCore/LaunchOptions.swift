import Foundation

public enum InitialScreen: String, CaseIterable, Sendable, Equatable {
    case dropdown
    case statistics
    case accounts
}

public struct LaunchOptions: Sendable, Equatable {
    public let isDemo: Bool
    public let demoScenario: DemoScenario
    public let openScreen: InitialScreen?
    public let selectedProvider: ProviderID?
    public let statisticsFilter: StatisticsFilter
    public let statisticsRange: StatisticsRange
    public let snapshotDir: URL?
    public let printWindowFrames: Bool
    public let dumpTokenSummary: Bool

    public init(
        isDemo: Bool = false,
        demoScenario: DemoScenario = .all,
        openScreen: InitialScreen? = nil,
        selectedProvider: ProviderID? = nil,
        statisticsFilter: StatisticsFilter? = nil,
        statisticsRange: StatisticsRange = .thirtyDays,
        snapshotDir: URL? = nil,
        printWindowFrames: Bool = false,
        dumpTokenSummary: Bool = false
    ) {
        self.isDemo = isDemo
        self.demoScenario = demoScenario
        self.openScreen = openScreen
        self.selectedProvider = selectedProvider
        if let statisticsFilter {
            self.statisticsFilter = statisticsFilter
        } else if let selectedProvider {
            self.statisticsFilter = .provider(selectedProvider)
        } else {
            self.statisticsFilter = .overview
        }
        self.statisticsRange = statisticsRange
        self.snapshotDir = snapshotDir
        self.printWindowFrames = printWindowFrames
        self.dumpTokenSummary = dumpTokenSummary
    }

    public static func parse(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchOptions {
        var isDemo = false
        if let envValue = environment["OPENUSAGE_DEMO"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            isDemo = envValue == "1" || envValue == "true" || envValue == "yes"
        }

        var demoScenario: DemoScenario = .all
        var openScreen: InitialScreen?
        var selectedProvider: ProviderID?
        var statisticsFilter: StatisticsFilter = .overview
        var statisticsRange: StatisticsRange = .thirtyDays
        var snapshotDir: URL?
        var printWindowFrames = false
        var dumpTokenSummary = false

        func applySelect(_ rawValue: String) {
            if let parsed = StatisticsFilter(cliValue: rawValue) {
                statisticsFilter = parsed
                selectedProvider = parsed.providerID
            }
        }

        func applyRange(_ rawValue: String) {
            if let parsed = StatisticsRange(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                statisticsRange = parsed
            }
        }

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--demo" {
                isDemo = true
                index += 1
            } else if arg == "--demo-scenario", index + 1 < arguments.count {
                if let parsed = DemoScenario(rawValue: arguments[index + 1].lowercased()) {
                    demoScenario = parsed
                }
                index += 2
            } else if arg.hasPrefix("--demo-scenario=") {
                let value = String(arg.dropFirst("--demo-scenario=".count)).lowercased()
                if let parsed = DemoScenario(rawValue: value) {
                    demoScenario = parsed
                }
                index += 1
            } else if arg == "--open", index + 1 < arguments.count {
                if let parsed = InitialScreen(rawValue: arguments[index + 1].lowercased()) {
                    openScreen = parsed
                }
                index += 2
            } else if arg.hasPrefix("--open=") {
                let value = String(arg.dropFirst("--open=".count)).lowercased()
                if let parsed = InitialScreen(rawValue: value) {
                    openScreen = parsed
                }
                index += 1
            } else if arg == "--select", index + 1 < arguments.count {
                applySelect(arguments[index + 1])
                index += 2
            } else if arg.hasPrefix("--select=") {
                let value = String(arg.dropFirst("--select=".count))
                applySelect(value)
                index += 1
            } else if arg == "--range", index + 1 < arguments.count {
                applyRange(arguments[index + 1])
                index += 2
            } else if arg.hasPrefix("--range=") {
                let value = String(arg.dropFirst("--range=".count))
                applyRange(value)
                index += 1
            } else if arg == "--snapshot-dir", index + 1 < arguments.count {
                let path = arguments[index + 1]
                if !path.isEmpty {
                    snapshotDir = URL(fileURLWithPath: path, isDirectory: true)
                }
                index += 2
            } else if arg.hasPrefix("--snapshot-dir=") {
                let path = String(arg.dropFirst("--snapshot-dir=".count))
                if !path.isEmpty {
                    snapshotDir = URL(fileURLWithPath: path, isDirectory: true)
                }
                index += 1
            } else if arg == "--print-window-frames" {
                printWindowFrames = true
                index += 1
            } else if arg == "--dump-token-summary" {
                dumpTokenSummary = true
                index += 1
            } else {
                index += 1
            }
        }

        return LaunchOptions(
            isDemo: isDemo,
            demoScenario: demoScenario,
            openScreen: openScreen,
            selectedProvider: selectedProvider,
            statisticsFilter: statisticsFilter,
            statisticsRange: statisticsRange,
            snapshotDir: snapshotDir,
            printWindowFrames: printWindowFrames,
            dumpTokenSummary: dumpTokenSummary
        )
    }
}
