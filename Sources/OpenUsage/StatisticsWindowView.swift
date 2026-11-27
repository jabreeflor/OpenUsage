import CoreGraphics
import OpenUsageCore
import SwiftUI

/// Live Statistics window wrapper bound to `AppStore`.
struct StatisticsWindowView: View {
    let store: AppStore

    var body: some View {
        StatisticsContentView(
            snapshots: store.snapshots,
            summary: store.statisticsSummary(),
            yellowFrom: store.thresholds.yellowFrom,
            redFrom: store.thresholds.redFrom,
            showsSimulatedTrafficLights: false,
            onSelectRange: { store.statisticsRange = $0 },
            onSelectFilter: { store.statisticsFilter = $0 }
        )
    }
}

/// Pure SwiftUI Statistics window content shared between the live `NSWindow` and `--snapshot-dir` rendering.
struct StatisticsContentView: View {
    let snapshots: [ProviderSnapshot]
    let summary: StatisticsSummary
    let yellowFrom: Int
    let redFrom: Int
    let showsSimulatedTrafficLights: Bool
    let onSelectRange: (StatisticsRange) -> Void
    let onSelectFilter: (StatisticsFilter) -> Void

    private func snapshot(for provider: ProviderID) -> ProviderSnapshot {
        snapshots.first(where: { $0.provider == provider }) ?? ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )
    }

    private var overallFullestPercent: Int? {
        snapshots
            .filter { $0.connectionState == .connected }
            .compactMap { $0.fullestLimit?.percentUsed }
            .max()
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle()
                .fill(Theme.divider.swiftUIColor)
                .frame(height: 1)

            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Theme.divider.swiftUIColor)
                    .frame(width: 1)
                mainContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background.swiftUIColor)
        .ignoresSafeArea(.container, edges: .top)
        .modifier(SnapshotWindowChromeModifier(enabled: showsSimulatedTrafficLights))
        .preferredColorScheme(.dark)
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 16) {
            // 52×12 leading slot aligned with the native macOS traffic lights (x = 16...68, centered at y = 26).
            Color.clear
                .frame(width: 52, height: 12)
                .overlay {
                    if showsSimulatedTrafficLights {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.trafficClose.swiftUIColor).frame(width: 12, height: 12)
                            Circle().fill(Theme.trafficMinimize.swiftUIColor).frame(width: 12, height: 12)
                            Circle().fill(Theme.trafficZoom.swiftUIColor).frame(width: 12, height: 12)
                        }
                    }
                }

            Text("Statistics")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.swiftUIColor)

            Spacer(minLength: 16)

            rangeSegmentedControl
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var rangeSegmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(StatisticsRange.allCases) { range in
                let isSelected = summary.range == range
                Button {
                    onSelectRange(range)
                } label: {
                    Text(range.label)
                        .font(Theme.mono(size: 12, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white : Theme.textMuted.swiftUIColor)
                        .frame(minWidth: 58, minHeight: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Theme.segmentedActive.swiftUIColor : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Range \(range.label)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.cardBackground.swiftUIColor)
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            SidebarRowView(
                title: "Overview",
                totalText: TokenFormatter.formatTokens(summary.sidebarTotal(for: .overview)),
                percent: overallFullestPercent,
                yellowFrom: yellowFrom,
                redFrom: redFrom,
                isSelected: summary.filter == .overview,
                icon: .overview,
                onTap: { onSelectFilter(.overview) }
            )

            ForEach(ProviderID.allCases) { provider in
                let snap = snapshot(for: provider)
                let percent = snap.connectionState == .connected ? snap.fullestLimit?.percentUsed : nil
                SidebarRowView(
                    title: provider.displayName,
                    totalText: TokenFormatter.formatTokens(summary.sidebarTotal(for: .provider(provider))),
                    percent: percent,
                    yellowFrom: yellowFrom,
                    redFrom: redFrom,
                    isSelected: summary.filter == .provider(provider),
                    icon: .provider(provider),
                    onTap: { onSelectFilter(.provider(provider)) }
                )
            }

            Spacer(minLength: 0)
        }
        .frame(width: 200, alignment: .topLeading)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: 216, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Heading + date range
            HStack(alignment: .firstTextBaseline) {
                Text(summary.heading)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)
                Spacer(minLength: 8)
                Text(summary.dateRangeText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
            }

            // Ring gauges row
            ringsRow

            // KPI cards row
            kpiRow

            // Tokens per day stacked bar chart
            TokensPerDayCardView(summary: summary)

            // Bottom split: Most used models + When you use AI heatmap
            ProportionalSplitLayout(ratios: [1.2, 1.0], spacing: 10) {
                MostUsedModelsCardView(models: summary.topModels)
                UsageHeatmapCardView(rows: summary.heatmapRows)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Ring Gauges Row

    private var gaugeCardItems: [StatsGaugeItem] {
        switch summary.filter {
        case .overview:
            return ProviderID.allCases.map { provider in
                let snap = snapshot(for: provider)
                if snap.connectionState == .connected, let fullest = snap.fullestLimit {
                    return StatsGaugeItem(
                        id: provider.rawValue,
                        provider: provider,
                        percent: fullest.percentUsed,
                        label: "\(provider.displayName) \u{00B7} \(fullest.statsLabel)"
                    )
                }
                let fallbackLabel: String
                switch snap.connectionState {
                case .expired: fallbackLabel = "\(provider.displayName) \u{00B7} Expired"
                case .connecting: fallbackLabel = "\(provider.displayName) \u{00B7} Connecting"
                case .unsupported: fallbackLabel = "\(provider.displayName) \u{00B7} Unsupported"
                case .notConnected, .connected: fallbackLabel = "\(provider.displayName) \u{00B7} Off"
                }
                return StatsGaugeItem(
                    id: provider.rawValue,
                    provider: provider,
                    percent: nil,
                    label: fallbackLabel
                )
            }

        case .provider(let provider):
            let snap = snapshot(for: provider)
            if snap.connectionState == .connected, !snap.limits.isEmpty {
                return snap.limits.map { limit in
                    StatsGaugeItem(
                        id: limit.id,
                        provider: provider,
                        percent: limit.percentUsed,
                        label: limit.statsLabel
                    )
                }
            }
            let statusLabel: String
            switch snap.connectionState {
            case .expired: statusLabel = "Sign-in expired"
            case .connecting: statusLabel = "Connecting"
            case .unsupported: statusLabel = "Not supported"
            case .notConnected, .connected: statusLabel = "Not connected"
            }
            return [
                StatsGaugeItem(
                    id: "\(provider.rawValue)-empty",
                    provider: provider,
                    percent: nil,
                    label: statusLabel
                )
            ]
        }
    }

    private var ringsRow: some View {
        let items = gaugeCardItems
        let columnCount = max(5, items.count)
        return HStack(spacing: 8) {
            ForEach(0..<columnCount, id: \.self) { index in
                if index < items.count {
                    StatsRingCardView(
                        item: items[index],
                        yellowFrom: yellowFrom,
                        redFrom: redFrom
                    )
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                }
            }
        }
    }

    // MARK: - KPI Cards Row

    private var kpiRow: some View {
        let tokens = summary.tokenSummary
        let splitText = "\(TokenFormatter.formatTokens(tokens.inputTokens)) \u{00B7} \(TokenFormatter.formatTokens(tokens.outputTokens)) \u{00B7} \(TokenFormatter.formatTokens(tokens.cacheTokens))"

        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                KPICardView(
                    title: "TOTAL TOKENS",
                    value: TokenFormatter.formatTokens(tokens.totalTokens),
                    valueColor: Theme.textPrimary.swiftUIColor
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("IN \u{00B7} OUT \u{00B7} CACHE")
                        .font(.system(size: 10))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textMuted.swiftUIColor)

                    InOutCacheBarView(
                        inputTokens: tokens.inputTokens,
                        outputTokens: tokens.outputTokens,
                        cacheTokens: tokens.cacheTokens
                    )

                    Text(splitText)
                        .font(Theme.mono(size: 11, weight: .regular))
                        .foregroundStyle(Theme.textSecondary.swiftUIColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.cardBackground.swiftUIColor)
                )

                KPICardView(
                    title: "REQUESTS",
                    value: TokenFormatter.formatCount(tokens.requests),
                    valueColor: Theme.textPrimary.swiftUIColor
                )

                KPICardView(
                    title: "LIMITS HIT",
                    value: summary.limitsHitDisplayText,
                    valueColor: summary.limitsHitAvailable
                        ? Theme.limitsHitRed.swiftUIColor
                        : Theme.textMuted.swiftUIColor
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Window Chrome Modifier (Snapshot only)

private struct SnapshotWindowChromeModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .frame(width: 1000, height: 748)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.border.swiftUIColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            content
                .frame(minWidth: 1000, idealWidth: 1000, minHeight: 748, idealHeight: 748)
        }
    }
}

// MARK: - Sidebar Row

private enum SidebarIcon {
    case overview
    case provider(ProviderID)
}

private struct SidebarRowView: View {
    let title: String
    let totalText: String
    let percent: Int?
    let yellowFrom: Int
    let redFrom: Int
    let isSelected: Bool
    let icon: SidebarIcon
    let onTap: () -> Void

    private var ringColor: Color? {
        guard let percent else { return nil }
        return DepletionColor.rgb(percent: percent, yellow: yellowFrom, red: redFrom).swiftUIColor
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Theme.ringTrack.swiftUIColor, lineWidth: 2.5)
                        .frame(width: 22, height: 22)

                    if let percent, let ringColor, percent > 0 {
                        Circle()
                            .trim(from: 0, to: CGFloat(min(100, max(0, percent))) / 100.0)
                            .stroke(
                                ringColor,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 22, height: 22)
                    }

                    iconView
                        .frame(width: 12, height: 12)
                }
                .frame(width: 26, height: 26)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(totalText)
                    .font(Theme.mono(size: 11, weight: .regular))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Theme.selectedBackground.swiftUIColor : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.sidebarSelectedBorder.swiftUIColor : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(totalText) tokens")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var iconView: some View {
        let iconColor = percent == nil ? Theme.dimmedIcon.swiftUIColor : Theme.textPrimary.swiftUIColor
        switch icon {
        case .overview:
            OverviewGridShape()
                .fill(iconColor)
        case .provider(let provider):
            ProviderLogoShape(provider: provider)
                .fill(iconColor)
        }
    }
}

private struct OverviewGridShape: Shape {
    private static let svgPath = "M3 3h8v8H3zM13 3h8v8h-8zM3 13h8v8H3zM13 13h8v8h-8z"

    func path(in rect: CGRect) -> Path {
        let raw = SVGPathParser.parse(Self.svgPath)
        let scale = min(rect.width / 24.0, rect.height / 24.0)
        let offsetX = rect.minX + (rect.width - 24.0 * scale) / 2.0
        let offsetY = rect.minY + (rect.height - 24.0 * scale) / 2.0
        var transform = CGAffineTransform(translationX: offsetX, y: offsetY)
            .scaledBy(x: scale, y: scale)
        guard let scaled = raw.copy(using: &transform) else {
            return Path()
        }
        return Path(scaled)
    }
}

// MARK: - Ring Gauge Card

private struct StatsGaugeItem: Identifiable {
    let id: String
    let provider: ProviderID
    let percent: Int?
    let label: String
}

private struct StatsRingCardView: View {
    let item: StatsGaugeItem
    let yellowFrom: Int
    let redFrom: Int

    private var ringColor: Color? {
        guard let percent = item.percent else { return nil }
        return DepletionColor.rgb(percent: percent, yellow: yellowFrom, red: redFrom).swiftUIColor
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Theme.ringTrack.swiftUIColor, lineWidth: 5)
                    .frame(width: 36, height: 36)

                if let percent = item.percent, let ringColor, percent > 0 {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(100, max(0, percent))) / 100.0)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 36, height: 36)
                }

                ProviderLogoShape(provider: item.provider)
                    .fill(item.percent == nil ? Theme.dimmedIcon.swiftUIColor : Theme.textPrimary.swiftUIColor)
                    .frame(width: 14, height: 14)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.percent.map { "\($0)%" } ?? "--")
                    .font(Theme.mono(size: 16, weight: .bold))
                    .foregroundStyle(ringColor ?? Theme.dimmedIcon.swiftUIColor)
                    .lineLimit(1)

                Text(item.label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground.swiftUIColor)
        )
    }
}

// MARK: - KPI Cards

private struct KPICardView: View {
    let title: String
    let value: String
    let valueColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted.swiftUIColor)

            Text(value)
                .font(Theme.mono(size: 22, weight: .bold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground.swiftUIColor)
        )
    }
}

private struct InOutCacheBarView: View {
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int

    var body: some View {
        Canvas { context, size in
            let clipPath = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            context.clip(to: clipPath)

            let parts: [(weight: Int, color: Color)] = [
                (inputTokens, Theme.modelShades[0].swiftUIColor),
                (outputTokens, Theme.modelShades[1].swiftUIColor),
                (cacheTokens, Theme.modelShades[2].swiftUIColor)
            ].filter { $0.weight > 0 }

            guard !parts.isEmpty else {
                context.fill(clipPath, with: .color(Theme.barTrack.swiftUIColor))
                return
            }

            let gap: CGFloat = 2
            let totalGap = gap * CGFloat(max(0, parts.count - 1))
            let usableWidth = max(0, size.width - totalGap)
            let totalWeight = parts.reduce(CGFloat(0)) { $0 + CGFloat($1.weight) }

            var x: CGFloat = 0
            for (index, part) in parts.enumerated() {
                let isLast = index == parts.count - 1
                let width = isLast
                    ? max(0, size.width - x)
                    : usableWidth * (CGFloat(part.weight) / totalWeight)
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(part.color))
                x += width + gap
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Tokens Per Day Chart

private struct TokensPerDayCardView: View {
    let summary: StatisticsSummary

    private let plotHeight: CGFloat = 140

    private var barSpacing: CGFloat {
        summary.range == .sevenDays ? 18 : 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Tokens per day")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)

                Spacer(minLength: 8)

                HStack(spacing: 12) {
                    ForEach(summary.visibleProviders) { provider in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(provider.seriesColor.swiftUIColor)
                                .frame(width: 9, height: 9)
                            Text(provider.displayName)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary.swiftUIColor)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                // Y-axis labels
                VStack(alignment: .trailing, spacing: 0) {
                    Text(summary.yAxisTop > 0 ? TokenFormatter.formatTokens(summary.yAxisTop) : "")
                    Spacer(minLength: 0)
                    Text(summary.yAxisMid > 0 ? TokenFormatter.formatTokens(summary.yAxisMid) : "")
                    Spacer(minLength: 0)
                    Text("0")
                }
                .font(Theme.mono(size: 10, weight: .regular))
                .foregroundStyle(Theme.textMuted.swiftUIColor)
                .frame(width: 38, height: plotHeight, alignment: .trailing)

                // Bars + X-axis labels
                VStack(spacing: 6) {
                    VStack(spacing: 0) {
                        ZStack {
                            HStack(alignment: .bottom, spacing: barSpacing) {
                                ForEach(summary.dailyBars) { bar in
                                    StackedDayBarView(
                                        bar: bar,
                                        yAxisTop: summary.yAxisTop,
                                        plotHeight: plotHeight
                                    )
                                    .help(bar.tooltipText)
                                }
                            }
                            .frame(height: plotHeight, alignment: .bottom)

                            if summary.tokenSummary.totalTokens == 0 {
                                Text("No token usage recorded in this range")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                            }
                        }

                        Rectangle()
                            .fill(Theme.border.swiftUIColor)
                            .frame(height: 1)
                    }

                    HStack(spacing: barSpacing) {
                        ForEach(summary.dailyBars) { bar in
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 13)
                                .overlay {
                                    if !bar.axisLabel.isEmpty {
                                        Text(bar.axisLabel)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.textMuted.swiftUIColor)
                                            .fixedSize()
                                    }
                                }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground.swiftUIColor)
        )
    }
}

private struct StackedDayBarView: View {
    let bar: DailyTokenBar
    let yAxisTop: Int
    let plotHeight: CGFloat

    var body: some View {
        let nonZero = bar.segments.filter { $0.tokens > 0 }
        let topDown = Array(nonZero.reversed())

        VStack(spacing: 1) {
            ForEach(topDown) { segment in
                let rawHeight = yAxisTop > 0
                    ? (CGFloat(segment.tokens) / CGFloat(yAxisTop)) * plotHeight
                    : 0
                let segHeight = max(1.0, rawHeight.rounded())
                Rectangle()
                    .fill(segment.provider.seriesColor.swiftUIColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: segHeight)
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 3,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 3,
                style: .continuous
            )
        )
        .frame(maxWidth: .infinity, maxHeight: plotHeight, alignment: .bottom)
    }
}

// MARK: - Most Used Models Card

private struct MostUsedModelsCardView: View {
    let models: [ModelUsageRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Most used models")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.swiftUIColor)
                .padding(.bottom, 2)

            if models.isEmpty {
                Text("No model usage recorded in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                    .padding(.vertical, 8)
            } else {
                ForEach(models) { row in
                    HStack(alignment: .center, spacing: 8) {
                        ProviderLogoShape(provider: row.provider)
                            .fill(Theme.textPrimary.swiftUIColor)
                            .frame(width: 13, height: 13)
                            .frame(width: 16, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            modelNameText(row)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)

                            ModelShareBarView(
                                fraction: row.relativeToTop,
                                color: row.provider.seriesColor.swiftUIColor
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(TokenFormatter.formatTokens(row.tokens))
                            .font(Theme.mono(size: 11, weight: .regular))
                            .foregroundStyle(Theme.textPrimary.swiftUIColor)
                            .frame(width: 58, alignment: .trailing)
                            .lineLimit(1)

                        Text("\(row.sharePercent)%")
                            .font(Theme.mono(size: 11, weight: .regular))
                            .foregroundStyle(Theme.textMuted.swiftUIColor)
                            .frame(width: 34, alignment: .trailing)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground.swiftUIColor)
        )
    }

    private func modelNameText(_ row: ModelUsageRow) -> Text {
        if let via = row.viaText {
            return Text(row.model)
                .foregroundStyle(Theme.textPrimary.swiftUIColor)
                + Text(" \(via)")
                .foregroundStyle(Theme.textMuted.swiftUIColor)
        }
        return Text(row.model)
            .foregroundStyle(Theme.textPrimary.swiftUIColor)
    }
}

private struct ModelShareBarView: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            let radius = size.height / 2
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)
            context.fill(track, with: .color(Theme.barTrack.swiftUIColor))

            let clamped = CGFloat(min(1.0, max(0.0, fraction)))
            let width = size.width * clamped
            if width > 0 {
                let fill = Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height), cornerRadius: radius)
                context.fill(fill, with: .color(color))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - When You Use AI Heatmap Card

private struct UsageHeatmapCardView: View {
    let rows: [HeatmapRow]

    private let hourLabels = ["12 AM", "6 AM", "12 PM", "6 PM", "11 PM"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When you use AI")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.swiftUIColor)

            VStack(spacing: 3) {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(row.dayLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted.swiftUIColor)
                            .frame(width: 26, height: 12, alignment: .leading)

                        HStack(spacing: 2) {
                            ForEach(row.cells) { cell in
                                let opacity = 0.06 + cell.intensity * 0.85
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Color(.sRGB, red: 244.0 / 255.0, green: 244.0 / 255.0, blue: 245.0 / 255.0, opacity: opacity))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 11)
                            }
                        }
                    }
                    .frame(height: 12)
                }
            }

            HStack(spacing: 0) {
                ForEach(Array(hourLabels.enumerated()), id: \.offset) { index, label in
                    if index > 0 {
                        Spacer(minLength: 0)
                    }
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted.swiftUIColor)
                }
            }
            .frame(height: 12)
            .padding(.leading, 32)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground.swiftUIColor)
        )
    }
}

// MARK: - Proportional 2-Column Split Layout

private struct ProportionalSplitLayout: Layout {
    let ratios: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }

        let proposedWidth = proposal.width ?? 740
        let totalWidth = proposedWidth > 0 ? proposedWidth : 740
        let totalSpacing = spacing * CGFloat(max(0, count - 1))
        let usableWidth = max(0, totalWidth - totalSpacing)
        let widths = columnWidths(count: count, usableWidth: usableWidth)

        var maxHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil))
            maxHeight = max(maxHeight, size.height)
        }
        return CGSize(width: totalWidth, height: maxHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let count = subviews.count
        guard count > 0 else { return }

        let totalSpacing = spacing * CGFloat(max(0, count - 1))
        let usableWidth = max(0, bounds.width - totalSpacing)
        let widths = columnWidths(count: count, usableWidth: usableWidth)

        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let w = widths[index]
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: w, height: bounds.height)
            )
            x += w + spacing
        }
    }

    private func columnWidths(count: Int, usableWidth: CGFloat) -> [CGFloat] {
        let effectiveRatios = (0..<count).map { index in
            index < ratios.count ? max(0.01, ratios[index]) : 1.0
        }
        let sum = effectiveRatios.reduce(0, +)
        return effectiveRatios.map { usableWidth * ($0 / sum) }
    }
}
