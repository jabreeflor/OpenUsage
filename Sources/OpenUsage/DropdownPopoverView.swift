import OpenUsageCore
import SwiftUI

/// Live MenuBarExtra popover wrapper that connects `AppStore`, `AppRouter`, refresh lifecycle, and window chrome cleanup.
struct DropdownPopoverView: View {
    let store: AppStore
    let router: AppRouter

    var body: some View {
        DropdownContentView(
            snapshots: store.snapshots,
            todayUsage: store.todayUsage,
            selection: store.selectedTile,
            yellowFrom: store.thresholds.yellowFrom,
            redFrom: store.thresholds.redFrom,
            updatedAgoText: store.updatedAgoText(),
            onSelect: { store.selectedTile = $0 },
            onOpenStatistics: {
                router.openStatistics()
            },
            onOpenAccounts: { provider in
                router.openAccounts(focus: provider)
            },
            onQuit: {
                router.quit()
            }
        )
        .background(MenuBarWindowChromeCleaner())
        .clearMenuBarWindowBackground()
        .onAppear {
            store.setDropdownOpen(true)
        }
        .onDisappear {
            store.setDropdownOpen(false)
        }
    }
}

private extension View {
    @ViewBuilder
    func clearMenuBarWindowBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(.clear, for: .window)
        } else {
            self
        }
    }
}

/// Pure SwiftUI view shared between the live `MenuBarExtra` popover and offscreen `--snapshot-dir` rendering.
struct DropdownContentView: View {
    let snapshots: [ProviderSnapshot]
    let todayUsage: TodayUsageSummary
    let selection: DropdownSelection
    let yellowFrom: Int
    let redFrom: Int
    let updatedAgoText: String
    let onSelect: (DropdownSelection) -> Void
    let onOpenStatistics: () -> Void
    let onOpenAccounts: (ProviderID?) -> Void
    let onQuit: () -> Void

    private func snapshot(for provider: ProviderID) -> ProviderSnapshot {
        snapshots.first(where: { $0.provider == provider }) ?? ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("Usage")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)
                Spacer()
                Text(updatedAgoText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
            }

            // 3x2 Gauge tiles grid
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    providerTile(for: .claude)
                    providerTile(for: .chatgpt)
                    providerTile(for: .cursor)
                }
                GridRow {
                    providerTile(for: .gemini)
                    providerTile(for: .opencode)
                    TodayTileView(
                        today: todayUsage,
                        isSelected: selection == .today,
                        onTap: { onSelect(.today) }
                    )
                }
            }

            // Detail card for selected tile
            detailCard

            // Footer links
            HStack {
                FooterLinkButton(title: "Statistics", action: onOpenStatistics)
                Spacer()
                FooterLinkButton(title: "Accounts") {
                    onOpenAccounts(nil)
                }
                Spacer()
                FooterLinkButton(title: "Quit", action: onQuit)
            }
            .padding(.horizontal, 2)
        }
        // 1 pt strokeBorder + 14 pt inner padding matches FinalDropdown.dc.html (border: 1px; padding: 14px)
        .padding(15)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.background.swiftUIColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.border.swiftUIColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private func providerTile(for provider: ProviderID) -> some View {
        let snap = snapshot(for: provider)
        return ProviderTileView(
            snapshot: snap,
            isSelected: selection == .provider(provider),
            yellowFrom: yellowFrom,
            redFrom: redFrom,
            onTap: { onSelect(.provider(provider)) }
        )
    }

    @ViewBuilder
    private var detailCard: some View {
        switch selection {
        case .provider(let provider):
            let snap = snapshot(for: provider)
            ProviderDetailCardView(
                snapshot: snap,
                todayUsage: todayUsage.usage(for: provider),
                yellowFrom: yellowFrom,
                redFrom: redFrom,
                onOpenAccounts: { onOpenAccounts(provider) }
            )
        case .today:
            TodayDetailCardView(today: todayUsage)
        }
    }
}

// MARK: - Provider Tile

private struct ProviderTileView: View {
    let snapshot: ProviderSnapshot
    let isSelected: Bool
    let yellowFrom: Int
    let redFrom: Int
    let onTap: () -> Void

    private var isConnectedWithLimits: Bool {
        snapshot.connectionState == .connected && snapshot.fullestLimit != nil
    }

    private var depletionColor: Color? {
        guard let fullest = snapshot.fullestLimit, snapshot.connectionState == .connected else {
            return nil
        }
        return DepletionColor.rgb(
            percent: fullest.percentUsed,
            yellow: yellowFrom,
            red: redFrom
        ).swiftUIColor
    }

    private var subtitleText: String {
        switch snapshot.connectionState {
        case .connected:
            return snapshot.fullestLimit?.shortName ?? "Connected"
        case .expired:
            return "Sign-in expired"
        case .notConnected:
            return "Not connected"
        case .connecting:
            return "Connecting"
        case .waitingForKeychain:
            return "Waiting for Keychain access"
        case .unsupported:
            return "Not yet supported"
        }
    }

    private var subtitleColor: Color {
        switch snapshot.connectionState {
        case .expired:
            return DepletionLevel.yellow.rgb.swiftUIColor
        default:
            return Theme.textMuted.swiftUIColor
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                RingGaugeView(
                    provider: snapshot.provider,
                    percent: isConnectedWithLimits ? snapshot.fullestLimit?.percentUsed : nil,
                    ringColor: depletionColor,
                    isDimmed: !isConnectedWithLimits
                )

                Text(isConnectedWithLimits ? "\(snapshot.fullestLimit?.percentUsed ?? 0)%" : "--")
                    .font(Theme.mono(size: 17, weight: .bold))
                    .foregroundStyle(depletionColor ?? Theme.dimmedIcon.swiftUIColor)
                    .lineLimit(1)

                Text(snapshot.provider.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary.swiftUIColor)
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.system(size: 10))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(.top, 12)
            .padding(.bottom, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.selectedBackground.swiftUIColor : Theme.cardBackground.swiftUIColor)
            )
            .overlay(tileBorder)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var tileBorder: some View {
        if isConnectedWithLimits {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.selectedBorder.swiftUIColor : Color.clear,
                    lineWidth: 1
                )
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.selectedBorder.swiftUIColor : Theme.dashedBorder.swiftUIColor,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
    }

    private var accessibilityLabel: String {
        if let pct = snapshot.fullestLimit?.percentUsed, snapshot.connectionState == .connected {
            return "\(snapshot.provider.displayName), \(pct) percent used, \(subtitleText)"
        }
        return "\(snapshot.provider.displayName), \(subtitleText)"
    }
}

private struct RingGaugeView: View {
    let provider: ProviderID
    let percent: Int?
    let ringColor: Color?
    let isDimmed: Bool

    var body: some View {
        ZStack {
            if isDimmed {
                // Disconnected/expired track: 64 pt outer diameter with 6 pt inset stroke (matches still 05).
                Circle()
                    .strokeBorder(Theme.ringTrack.swiftUIColor, lineWidth: 6)
                    .frame(width: 64, height: 64)
            } else {
                // Connected track ring: 64x64 container, r=27 (diameter 54), stroke width 6 (outer diameter 60).
                Circle()
                    .stroke(Theme.ringTrack.swiftUIColor, lineWidth: 6)
                    .frame(width: 54, height: 54)

                if let percent, let ringColor, percent > 0 {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(100, max(0, percent))) / 100.0)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 54, height: 54)
                }
            }

            ProviderLogoShape(provider: provider)
                .fill(isDimmed ? Theme.dimmedIcon.swiftUIColor : Theme.textPrimary.swiftUIColor)
                .frame(width: 20, height: 20)
        }
        .frame(width: 64, height: 64)
    }
}

// MARK: - Today Tile

private struct TodayTileView: View {
    let today: TodayUsageSummary
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TODAY")
                    .font(.system(size: 10))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textMuted.swiftUIColor)

                Spacer(minLength: 0)

                Text(TokenFormatter.formatTokens(today.totalTokens))
                    .font(Theme.mono(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                SparklineView(values: today.hourlySparkline)

                Spacer(minLength: 0)

                Text("tokens\u{00A0}·\u{00A0}\(TokenFormatter.formatCount(today.totalRequests)) requests")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(.top, 12)
            .padding(.bottom, 10)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.selectedBackground.swiftUIColor : Theme.cardBackground.swiftUIColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.selectedBorder.swiftUIColor : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Today, \(TokenFormatter.formatTokens(today.totalTokens)) tokens, \(today.totalRequests) requests")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SparklineView: View {
    let values: [Int]

    private var displayValues: [Int] {
        values.isEmpty ? Array(repeating: 0, count: 12) : values
    }

    var body: some View {
        let maxValue = max(1, displayValues.max() ?? 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(displayValues.enumerated()), id: \.offset) { _, value in
                let fraction = CGFloat(max(0, value)) / CGFloat(maxValue)
                let height = max(2.0, fraction * 26.0)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.sparklineBar.swiftUIColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
        .frame(height: 26, alignment: .bottom)
    }
}

// MARK: - Detail Cards

private struct ProviderDetailCardView: View {
    let snapshot: ProviderSnapshot
    let todayUsage: ProviderTodayUsage
    let yellowFrom: Int
    let redFrom: Int
    let onOpenAccounts: () -> Void

    private var isConnected: Bool {
        snapshot.connectionState == .connected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Provider header
            HStack(spacing: 8) {
                ProviderLogoShape(provider: snapshot.provider)
                    .fill(isConnected ? Theme.textPrimary.swiftUIColor : Theme.dimmedIcon.swiftUIColor)
                    .frame(width: 16, height: 16)

                Text(snapshot.provider.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)

                if !snapshot.plan.isEmpty {
                    Text(snapshot.plan)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted.swiftUIColor)
                }

                Spacer(minLength: 0)
            }

            if isConnected {
                connectedBody
            } else {
                disconnectedBody
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground.swiftUIColor)
        )
    }

    @ViewBuilder
    private var connectedBody: some View {
        ForEach(snapshot.limits) { limit in
            let color = DepletionColor.rgb(
                percent: limit.percentUsed,
                yellow: yellowFrom,
                red: redFrom
            ).swiftUIColor

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(limit.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary.swiftUIColor)
                    Spacer()
                    Text("\(limit.percentUsed)%")
                        .font(Theme.mono(size: 12, weight: .bold))
                        .foregroundStyle(color)
                }

                ProgressBarView(percent: limit.percentUsed, color: color)

                Text(limit.resetText)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                    .frame(height: 12, alignment: .leading)
            }
        }

        // Divider + Models today
        modelsTodaySection
    }

    private var modelsTodaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(Theme.border.swiftUIColor)
                .frame(height: 1)
                .padding(.bottom, 4)

            Text("MODELS TODAY · \(TokenFormatter.formatTokens(todayUsage.totalTokens)) TOKENS")
                .font(.system(size: 10))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted.swiftUIColor)
                .frame(height: 12, alignment: .leading)

            if !todayUsage.models.isEmpty {
                StackedBarView(
                    segments: todayUsage.models.enumerated().map { index, model in
                        StackedBarSegment(
                            id: model.id,
                            weight: max(1, CGFloat(model.sharePercent)),
                            color: Theme.modelShades[min(index, Theme.modelShades.count - 1)].swiftUIColor
                        )
                    }
                )

                FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(todayUsage.models.enumerated()), id: \.element.id) { index, model in
                        let shade = Theme.modelShades[min(index, Theme.modelShades.count - 1)].swiftUIColor
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(shade)
                                .frame(width: 8, height: 8)
                            (
                                Text(model.model)
                                    .foregroundStyle(Theme.textSecondary.swiftUIColor)
                                + Text(" \(model.sharePercent)%")
                                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                            )
                            .font(.system(size: 11))
                        }
                        .frame(height: 13)
                    }
                }
            } else {
                Text("No token usage recorded today")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
            }
        }
    }

    @ViewBuilder
    private var disconnectedBody: some View {
        let statusInfo = disconnectedStatusInfo

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(statusInfo.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusInfo.titleColor)

                Text(statusInfo.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
            }

            Button(action: onOpenAccounts) {
                Text(statusInfo.buttonTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusInfo.isPrimaryNeutral ? Theme.neutralButtonText.swiftUIColor : Theme.textSecondary.swiftUIColor)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(statusInfo.isPrimaryNeutral ? Theme.neutralButtonFill.swiftUIColor : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                statusInfo.isPrimaryNeutral ? Theme.neutralButtonFill.swiftUIColor : Theme.dashedBorder.swiftUIColor,
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)

            if todayUsage.totalTokens > 0 {
                modelsTodaySection
            }
        }
    }

    private var disconnectedStatusInfo: (title: String, titleColor: Color, detail: String, buttonTitle: String, isPrimaryNeutral: Bool) {
        switch snapshot.connectionState {
        case .expired:
            return (
                title: "Sign-in expired",
                titleColor: DepletionLevel.yellow.rgb.swiftUIColor,
                detail: snapshot.connectedVia.isEmpty ? "Reconnect your account in Accounts to refresh usage limits." : snapshot.connectedVia,
                buttonTitle: "Reconnect",
                isPrimaryNeutral: true
            )
        case .notConnected:
            return (
                title: "Not connected",
                titleColor: Theme.textSecondary.swiftUIColor,
                detail: "Sign in in Accounts to track live usage limits.",
                buttonTitle: "Sign in",
                isPrimaryNeutral: true
            )
        case .connecting:
            return (
                title: "Connecting",
                titleColor: Theme.textSecondary.swiftUIColor,
                detail: snapshot.connectedVia.isEmpty ? "Finish signing in in your browser." : snapshot.connectedVia,
                buttonTitle: "Open Accounts",
                isPrimaryNeutral: false
            )
        case .waitingForKeychain:
            return (
                title: "Waiting for Keychain access",
                titleColor: Theme.textSecondary.swiftUIColor,
                detail: "Approve the macOS Keychain prompt to load live usage limits.",
                buttonTitle: "Open Accounts",
                isPrimaryNeutral: false
            )
        case .unsupported, .connected:
            return (
                title: "Not yet supported",
                titleColor: Theme.textSecondary.swiftUIColor,
                detail: snapshot.connectedVia.isEmpty ? "Live limits are not yet supported for this provider." : snapshot.connectedVia,
                buttonTitle: "Open Accounts",
                isPrimaryNeutral: false
            )
        }
    }
}

private struct TodayDetailCardView: View {
    let today: TodayUsageSummary

    private var providerBreakdown: [ProviderTodayUsage] {
        ProviderID.allCases
            .map { today.usage(for: $0) }
            .filter { $0.totalTokens > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)
                Text("\(TokenFormatter.formatTokens(today.totalTokens)) tokens · \(TokenFormatter.formatCount(today.totalRequests)) requests")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                Spacer(minLength: 0)
            }

            if !providerBreakdown.isEmpty {
                StackedBarView(
                    segments: providerBreakdown.map { item in
                        StackedBarSegment(
                            id: item.provider.rawValue,
                            weight: CGFloat(item.totalTokens),
                            color: item.provider.seriesColor.swiftUIColor
                        )
                    }
                )

                FlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(providerBreakdown) { item in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(item.provider.seriesColor.swiftUIColor)
                                .frame(width: 8, height: 8)
                            (
                                Text(item.provider.displayName)
                                    .foregroundStyle(Theme.textSecondary.swiftUIColor)
                                + Text(" \(TokenFormatter.formatTokens(item.totalTokens))")
                                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                            )
                            .font(.system(size: 11))
                        }
                        .frame(height: 13)
                    }
                }
            } else {
                Text("No token usage recorded today")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground.swiftUIColor)
        )
    }
}

// MARK: - Primitives & Layouts

private struct ProgressBarView: View {
    let percent: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let radius = size.height / 2
            let trackRect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(roundedRect: trackRect, cornerRadius: radius),
                with: .color(Theme.barTrack.swiftUIColor)
            )

            let fraction = CGFloat(min(100, max(0, percent))) / 100.0
            let fillWidth = size.width * fraction
            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: fillWidth, height: size.height)
                context.fill(
                    Path(roundedRect: fillRect, cornerRadius: radius),
                    with: .color(color)
                )
            }
        }
        .frame(height: 6)
    }
}

private struct StackedBarSegment: Identifiable {
    let id: String
    let weight: CGFloat
    let color: Color
}

private struct StackedBarView: View {
    let segments: [StackedBarSegment]

    var body: some View {
        Canvas { context, size in
            let nonEmpty = segments.filter { $0.weight > 0 }
            guard !nonEmpty.isEmpty else { return }

            let gap: CGFloat = 2
            let totalGap = gap * CGFloat(max(0, nonEmpty.count - 1))
            let usableWidth = max(0, size.width - totalGap)
            let totalWeight = nonEmpty.reduce(CGFloat(0)) { $0 + $1.weight }
            guard totalWeight > 0 else { return }

            let clipPath = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            context.clip(to: clipPath)

            var x: CGFloat = 0
            for (index, segment) in nonEmpty.enumerated() {
                let isLast = index == nonEmpty.count - 1
                let width = isLast
                    ? max(0, size.width - x)
                    : usableWidth * (segment.weight / totalWeight)
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(rect), with: .color(segment.color))
                x += width + gap
            }
        }
        .frame(height: 8)
    }
}

private struct FooterLinkButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isHovering ? Theme.linkHoverColor.swiftUIColor : Theme.linkColor.swiftUIColor)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 12
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            measuredWidth = max(measuredWidth, currentX + size.width)
            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }

        let finalWidth = maxWidth.isFinite ? maxWidth : measuredWidth
        return CGSize(width: finalWidth, height: currentY + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX + 0.5 {
                currentX = bounds.minX
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
