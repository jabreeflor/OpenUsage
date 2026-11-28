import XCTest
@testable import OpenUsageCore

final class ModelAndFixtureTests: XCTestCase {
    func testFullestLimitSelection() {
        let empty = ProviderSnapshot(
            provider: .claude,
            plan: "Max 5x",
            connectionState: .connected,
            limits: [],
            connectedVia: "Signed in with claude.ai"
        )
        XCTAssertNil(empty.fullestLimit)

        let multi = ProviderSnapshot(
            provider: .claude,
            plan: "Max 5x",
            connectionState: .connected,
            limits: [
                UsageLimit(name: "A", percentUsed: 62, resetText: "r1"),
                UsageLimit(name: "B", percentUsed: 38, resetText: "r2"),
                UsageLimit(name: "C", percentUsed: 81, resetText: "r3")
            ],
            connectedVia: "Signed in with claude.ai"
        )
        XCTAssertEqual(multi.fullestLimit?.name, "C")
        XCTAssertEqual(multi.fullestLimit?.percentUsed, 81)

        // Tie breaks deterministically to first occurrence
        let tied = ProviderSnapshot(
            provider: .chatgpt,
            plan: "Plus",
            connectionState: .connected,
            limits: [
                UsageLimit(name: "First", percentUsed: 54, resetText: "r1"),
                UsageLimit(name: "Second", percentUsed: 54, resetText: "r2")
            ],
            connectedVia: "Signed in with ChatGPT"
        )
        XCTAssertEqual(tied.fullestLimit?.name, "First")
    }

    func testDemoScenarioAllMatchesReferenceStills() async throws {
        let providers = DemoFixtures.providers(for: .all)
        XCTAssertEqual(providers.map(\.provider), [.claude, .chatgpt, .cursor, .gemini, .opencode])

        var snapshots: [ProviderSnapshot] = []
        for provider in providers {
            snapshots.append(try await provider.fetchSnapshot())
        }

        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })

        // Claude
        let claude = try XCTUnwrap(byID[.claude])
        XCTAssertEqual(claude.plan, "Max 5x")
        XCTAssertEqual(claude.connectionState, .connected)
        XCTAssertEqual(claude.connectedVia, "Signed in with claude.ai")
        XCTAssertEqual(claude.limits.count, 3)
        XCTAssertEqual(claude.limits[0].name, "5-hour session")
        XCTAssertEqual(claude.limits[0].percentUsed, 62)
        XCTAssertEqual(claude.limits[0].resetText, "Resets in 2h 14m")
        XCTAssertEqual(claude.limits[1].name, "Weekly · all models")
        XCTAssertEqual(claude.limits[1].percentUsed, 38)
        XCTAssertEqual(claude.limits[1].resetText, "Resets Tue 9:00 AM")
        XCTAssertEqual(claude.limits[2].name, "Weekly · Opus")
        XCTAssertEqual(claude.limits[2].shortName, "Wk · Opus")
        XCTAssertEqual(claude.limits[2].percentUsed, 81)
        XCTAssertEqual(claude.limits[2].resetText, "Resets Tue 9:00 AM")
        XCTAssertEqual(claude.fullestLimit?.percentUsed, 81)
        XCTAssertEqual(claude.menuBarEntryState, .connected(percent: 81))

        // ChatGPT
        let chatgpt = try XCTUnwrap(byID[.chatgpt])
        XCTAssertEqual(chatgpt.plan, "Plus · Codex")
        XCTAssertEqual(chatgpt.connectionState, .connected)
        XCTAssertEqual(chatgpt.limits.map(\.percentUsed), [21, 54])
        XCTAssertEqual(chatgpt.fullestLimit?.name, "Weekly")
        XCTAssertEqual(chatgpt.fullestLimit?.percentUsed, 54)
        XCTAssertEqual(chatgpt.menuBarEntryState, .connected(percent: 54))

        // Cursor
        let cursor = try XCTUnwrap(byID[.cursor])
        XCTAssertEqual(cursor.plan, "Pro")
        XCTAssertEqual(cursor.connectionState, .connected)
        XCTAssertEqual(cursor.fullestLimit?.name, "Included usage")
        XCTAssertEqual(cursor.fullestLimit?.percentUsed, 67)
        XCTAssertEqual(cursor.fullestLimit?.resetText, "$13.40 of $20 · resets Dec 9")
        XCTAssertEqual(cursor.menuBarEntryState, .connected(percent: 67))

        // Gemini
        let gemini = try XCTUnwrap(byID[.gemini])
        XCTAssertEqual(gemini.plan, "Google AI Pro")
        XCTAssertEqual(gemini.connectionState, .connected)
        XCTAssertEqual(gemini.fullestLimit?.name, "Daily requests")
        XCTAssertEqual(gemini.fullestLimit?.percentUsed, 21)
        XCTAssertEqual(gemini.fullestLimit?.resetText, "312 of 1,500 · resets at midnight")
        XCTAssertEqual(gemini.menuBarEntryState, .connected(percent: 21))

        // OpenCode (Go three meters)
        let opencode = try XCTUnwrap(byID[.opencode])
        XCTAssertEqual(opencode.plan, "Go")
        XCTAssertEqual(opencode.connectionState, .connected)
        XCTAssertEqual(opencode.limits.count, 3)
        XCTAssertEqual(opencode.limits[0].name, "5-hour")
        XCTAssertEqual(opencode.limits[0].percentUsed, 24)
        XCTAssertEqual(opencode.limits[0].resetText, "Resets in 3h 18m")
        XCTAssertEqual(opencode.limits[1].name, "Weekly")
        XCTAssertEqual(opencode.limits[1].percentUsed, 42)
        XCTAssertEqual(opencode.limits[1].resetText, "Resets Mon 12:00 AM")
        XCTAssertEqual(opencode.limits[2].name, "Monthly")
        XCTAssertEqual(opencode.limits[2].percentUsed, 31)
        XCTAssertEqual(opencode.limits[2].resetText, "Resets Dec 1")
        XCTAssertEqual(opencode.fullestLimit?.name, "Weekly")
        XCTAssertEqual(opencode.fullestLimit?.percentUsed, 42)
        XCTAssertEqual(opencode.menuBarEntryState, .connected(percent: 42))
    }

    func testDemoScenarioDisconnected() {
        let snapshots = DemoFixtures.snapshots(for: .disconnected)
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })

        XCTAssertEqual(byID[.claude]?.connectionState, .connected)
        XCTAssertEqual(byID[.claude]?.menuBarEntryState, .connected(percent: 81))
        XCTAssertEqual(byID[.chatgpt]?.connectionState, .connected)
        XCTAssertEqual(byID[.chatgpt]?.menuBarEntryState, .connected(percent: 54))
        XCTAssertEqual(byID[.cursor]?.connectionState, .connected)
        XCTAssertEqual(byID[.cursor]?.menuBarEntryState, .connected(percent: 67))

        XCTAssertEqual(byID[.gemini]?.connectionState, .expired)
        XCTAssertEqual(byID[.gemini]?.limits, [])
        XCTAssertEqual(byID[.gemini]?.menuBarEntryState, .dimmedPlaceholder)

        XCTAssertEqual(byID[.opencode]?.connectionState, .notConnected)
        XCTAssertEqual(byID[.opencode]?.limits, [])
        XCTAssertEqual(byID[.opencode]?.menuBarEntryState, .omitted)
    }

    func testDemoScenarioConnecting() {
        let snapshots = DemoFixtures.snapshots(for: .connecting)
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })

        XCTAssertEqual(byID[.claude]?.menuBarEntryState, .connected(percent: 81))
        XCTAssertEqual(byID[.chatgpt]?.menuBarEntryState, .connected(percent: 54))
        XCTAssertEqual(byID[.cursor]?.menuBarEntryState, .connected(percent: 67))

        XCTAssertEqual(byID[.gemini]?.connectionState, .connecting)
        XCTAssertEqual(byID[.gemini]?.plan, "Google AI Pro")
        XCTAssertEqual(byID[.gemini]?.menuBarEntryState, .dimmedPlaceholder)

        XCTAssertEqual(byID[.opencode]?.connectionState, .notConnected)
        XCTAssertEqual(byID[.opencode]?.menuBarEntryState, .omitted)
    }

    func testUnconfiguredProviderIsHonestEmptyState() async throws {
        for id in ProviderID.allCases {
            let provider = UnconfiguredUsageProvider(provider: id)
            let snapshot = try await provider.fetchSnapshot()
            XCTAssertEqual(snapshot.provider, id)
            XCTAssertEqual(snapshot.connectionState, .notConnected)
            XCTAssertTrue(snapshot.limits.isEmpty)
            XCTAssertNil(snapshot.fullestLimit)
            XCTAssertEqual(snapshot.menuBarEntryState, .omitted)
        }
    }

    func testTokenBucketAggregation() {
        let buckets = [
            TokenBucket(
                dayKey: "2026-11-26",
                hour: 10,
                provider: .claude,
                model: "claude-opus-4.5",
                inputTokens: 1000,
                outputTokens: 400,
                cacheTokens: 3000,
                requests: 5
            ),
            TokenBucket(
                dayKey: "2026-11-26",
                hour: 11,
                provider: .chatgpt,
                model: "gpt-5-codex",
                inputTokens: 500,
                outputTokens: 200,
                cacheTokens: 1000,
                requests: 3
            )
        ]

        XCTAssertEqual(buckets[0].totalTokens, 4400)
        let summary = TokenSummary.aggregate(buckets)
        XCTAssertEqual(summary.inputTokens, 1500)
        XCTAssertEqual(summary.outputTokens, 600)
        XCTAssertEqual(summary.cacheTokens, 4000)
        XCTAssertEqual(summary.totalTokens, 6100)
        XCTAssertEqual(summary.requests, 8)
    }

    func testProviderLogoSVGPathsParseCleanly() {
        for provider in ProviderID.allCases {
            let path = provider.logoCGPath()
            XCTAssertFalse(path.isEmpty, "Expected non-empty CGPath for \(provider.rawValue)")
            let bounds = path.boundingBoxOfPath
            XCTAssertGreaterThan(bounds.width, 10, "Logo width unexpectedly tiny for \(provider.rawValue)")
            XCTAssertGreaterThan(bounds.height, 10, "Logo height unexpectedly tiny for \(provider.rawValue)")
            XCTAssertGreaterThanOrEqual(bounds.minX, -0.5)
            XCTAssertGreaterThanOrEqual(bounds.minY, -0.5)
            XCTAssertLessThanOrEqual(bounds.maxX, 24.5)
            XCTAssertLessThanOrEqual(bounds.maxY, 24.5)
        }
    }
}
