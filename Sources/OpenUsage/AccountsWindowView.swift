import CoreGraphics
import OpenUsageCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case accounts
    case alerts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .alerts: "Alerts"
        }
    }
}

/// Live Accounts settings window wrapper bound to `AppStore`.
struct AccountsWindowView: View {
    let store: AppStore
    let router: AppRouter

    @State private var selectedTab: SettingsTab = .accounts

    var body: some View {
        AccountsContentView(
            snapshots: store.snapshots,
            enabledSources: store.localSources.enabledSources,
            yellowFrom: store.thresholds.yellowFrom,
            redFrom: store.thresholds.redFrom,
            selectedTab: selectedTab,
            showsSimulatedTrafficLights: false,
            onSelectTab: { selectedTab = $0 },
            onSignIn: { provider in
                _ = store.accounts.signIn(provider)
            },
            onSignOut: { provider in
                _ = store.accounts.signOut(provider)
            },
            onToggleSource: { source in
                store.localSources.toggle(source)
            },
            onApplyYellowInput: { raw in
                store.thresholds.applyYellowInput(raw)
            },
            onApplyRedInput: { raw in
                store.thresholds.applyRedInput(raw)
            }
        )
        .onChange(of: router.focusedAccountProvider) { _, newValue in
            if newValue != nil {
                selectedTab = .accounts
            }
        }
    }
}

/// Pure SwiftUI Accounts settings content shared between the live `NSWindow` and `--snapshot-dir` rendering.
struct AccountsContentView: View {
    static let windowWidth: CGFloat = 780
    static let windowHeight: CGFloat = 652

    let snapshots: [ProviderSnapshot]
    let enabledSources: [LocalToolSource: Bool]
    let yellowFrom: Int
    let redFrom: Int
    let selectedTab: SettingsTab
    let showsSimulatedTrafficLights: Bool
    let onSelectTab: (SettingsTab) -> Void
    let onSignIn: (ProviderID) -> Void
    let onSignOut: (ProviderID) -> Void
    let onToggleSource: (LocalToolSource) -> Void
    let onApplyYellowInput: (String) -> Bool
    let onApplyRedInput: (String) -> Bool

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
        VStack(spacing: 0) {
            headerBar

            Rectangle()
                .fill(Theme.divider.swiftUIColor)
                .frame(height: 1)

            switch selectedTab {
            case .accounts:
                accountsBody
            case .general:
                placeholderTabBody(
                    title: "General",
                    message: "Usage limits refresh every 60 seconds while the menu bar popover is open, and every 5 minutes in the background. Additional general preferences are planned for a future update."
                )
            case .alerts:
                placeholderTabBody(
                    title: "Alerts",
                    message: "Depletion color thresholds can be configured in the Accounts tab. System notifications for approaching usage limits are planned for a future update."
                )
            }
        }
        .background(Theme.background.swiftUIColor)
        .ignoresSafeArea(.container, edges: .top)
        .modifier(AccountsWindowChromeModifier(enabled: showsSimulatedTrafficLights))
        .preferredColorScheme(.dark)
    }

    // MARK: - Header & Toolbar Tabs

    private var headerBar: some View {
        VStack(spacing: 6) {
            ZStack {
                HStack {
                    // 52×12 leading slot aligned with the native macOS traffic lights (x = 16...68, centered at y = 18).
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
                    Spacer(minLength: 0)
                }

                Text(selectedTab.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)
            }
            .frame(height: 16)

            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsTabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        onTap: { onSelectTab(tab) }
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Accounts Tab Body

    private var accountsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                subscriptionsSection
                localToolsSection
            }
            Spacer(minLength: 12)
            colorsFooterRow
        }
        .padding(.top, 18)
        .padding(.bottom, 13)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SUBSCRIPTIONS")
                .font(.system(size: 10))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted.swiftUIColor)

            VStack(spacing: 0) {
                ForEach(Array(ProviderID.allCases.enumerated()), id: \.element.id) { index, provider in
                    let snap = snapshot(for: provider)
                    SubscriptionAccountRow(
                        snapshot: snap,
                        yellowFrom: yellowFrom,
                        redFrom: redFrom,
                        isStaticSnapshot: showsSimulatedTrafficLights,
                        onSignIn: { onSignIn(provider) },
                        onSignOut: { onSignOut(provider) }
                    )

                    if index < ProviderID.allCases.count - 1 {
                        Rectangle()
                            .fill(Theme.divider.swiftUIColor)
                            .frame(height: 1)
                    }
                }
            }
            .background(Theme.cardBackground.swiftUIColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var localToolsSection: some View {
        let sources = LocalToolSource.allCases
        let columns = [
            GridItem(.flexible(), spacing: 24, alignment: .topLeading),
            GridItem(.flexible(), spacing: 24, alignment: .topLeading)
        ]

        return VStack(alignment: .leading, spacing: 8) {
            Text("COUNT TOKENS FROM LOCAL TOOLS")
                .font(.system(size: 10))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted.swiftUIColor)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(sources) { source in
                    LocalToolCheckboxRow(
                        source: source,
                        isChecked: enabledSources[source] ?? source.defaultEnabled,
                        onToggle: { onToggleSource(source) }
                    )
                }
            }
        }
    }

    private var colorsFooterRow: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.divider.swiftUIColor)
                .frame(height: 1)

            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("Colors")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted.swiftUIColor)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(DepletionLevel.green.rgb.swiftUIColor)
                            .frame(width: 8, height: 8)
                        Text("Green below yellow")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary.swiftUIColor)
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(DepletionLevel.yellow.rgb.swiftUIColor)
                            .frame(width: 8, height: 8)
                        Text("Yellow from")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary.swiftUIColor)
                    }

                    ThresholdPercentField(
                        value: yellowFrom,
                        accessibilityLabel: "Yellow threshold percent",
                        onApply: onApplyYellowInput
                    )

                    HStack(spacing: 6) {
                        Circle()
                            .fill(DepletionLevel.red.rgb.swiftUIColor)
                            .frame(width: 8, height: 8)
                        Text("Red from")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary.swiftUIColor)
                    }

                    ThresholdPercentField(
                        value: redFrom,
                        accessibilityLabel: "Red threshold percent",
                        onApply: onApplyRedInput
                    )
                }

                Spacer(minLength: 12)

                Text("Credentials stay in your Keychain")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Placeholder Tabs (General / Alerts)

    private func placeholderTabBody(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.cardBackground.swiftUIColor)
            )

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Window Chrome Modifier

private struct AccountsWindowChromeModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .frame(width: AccountsContentView.windowWidth, height: AccountsContentView.windowHeight, alignment: .top)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.border.swiftUIColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            content
                .frame(
                    minWidth: AccountsContentView.windowWidth,
                    idealWidth: AccountsContentView.windowWidth,
                    minHeight: AccountsContentView.windowHeight,
                    idealHeight: AccountsContentView.windowHeight,
                    alignment: .top
                )
        }
    }
}

// MARK: - Settings Tab Button & Vector Icons

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let tint = isSelected ? Theme.textPrimary.swiftUIColor : Theme.textMuted.swiftUIColor

        Button(action: onTap) {
            VStack(spacing: 3) {
                SettingsTabIconShape(tab: tab)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 18, height: 18)

                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(tint)
            }
            .frame(width: 84, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.selectedBackground.swiftUIColor : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsTabIconShape: Shape {
    let tab: SettingsTab

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 16.0, rect.height / 16.0)
        let ox = rect.minX + (rect.width - 16.0 * scale) / 2.0
        let oy = rect.minY + (rect.height - 16.0 * scale) / 2.0

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * scale, y: oy + y * scale)
        }

        var path = Path()
        switch tab {
        case .general:
            // Circle cx=8 cy=8 r=2.2 + 8 spokes from FinalAccounts.dc.html
            let r = 2.2 * scale
            path.addEllipse(in: CGRect(x: ox + 8 * scale - r, y: oy + 8 * scale - r, width: r * 2, height: r * 2))
            let spokes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (8, 1.5, 8, 3.5),
                (8, 12.5, 8, 14.5),
                (1.5, 8, 3.5, 8),
                (12.5, 8, 14.5, 8),
                (3.4, 3.4, 4.8, 4.8),
                (11.2, 11.2, 12.6, 12.6),
                (3.4, 12.6, 4.8, 11.2),
                (11.2, 4.8, 12.6, 3.4)
            ]
            for (x1, y1, x2, y2) in spokes {
                path.move(to: pt(x1, y1))
                path.addLine(to: pt(x2, y2))
            }

        case .accounts:
            // Head circle cx=8 cy=5.5 r=2.8 + shoulders arc M2.5 14c.8-2.6 3-4 5.5-4s4.7 1.4 5.5 4
            let r = 2.8 * scale
            path.addEllipse(in: CGRect(x: ox + 8 * scale - r, y: oy + 5.5 * scale - r, width: r * 2, height: r * 2))
            path.move(to: pt(2.5, 14))
            path.addCurve(to: pt(8, 10), control1: pt(3.3, 11.4), control2: pt(5.5, 10))
            path.addCurve(to: pt(13.5, 14), control1: pt(10.5, 10), control2: pt(12.7, 11.4))

        case .alerts:
            // Bell M4 11V7a4 4 0 0 1 8 0v4l1.2 1.5H2.8z + clapper M6.5 14a1.6 1.6 0 0 0 3 0
            path.move(to: pt(4, 11))
            path.addLine(to: pt(4, 7))
            path.addArc(
                center: pt(8, 7),
                radius: 4 * scale,
                startAngle: .degrees(180),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addLine(to: pt(12, 11))
            path.addLine(to: pt(13.2, 12.5))
            path.addLine(to: pt(2.8, 12.5))
            path.closeSubpath()

            path.move(to: pt(6.5, 14))
            path.addCurve(to: pt(9.5, 14), control1: pt(7.0, 15.2), control2: pt(9.0, 15.2))
        }
        return path
    }
}

// MARK: - Subscription Account Row

private struct SubscriptionAccountRow: View {
    let snapshot: ProviderSnapshot
    let yellowFrom: Int
    let redFrom: Int
    let isStaticSnapshot: Bool
    let onSignIn: () -> Void
    let onSignOut: () -> Void

    private var isConnected: Bool {
        snapshot.connectionState == .connected
    }

    private var fullestPercent: Int? {
        guard isConnected else { return nil }
        return snapshot.fullestLimit?.percentUsed
    }

    private var depletionColor: Color? {
        guard let percent = fullestPercent else { return nil }
        return DepletionColor.rgb(percent: percent, yellow: yellowFrom, red: redFrom).swiftUIColor
    }

    private var pillSpec: (label: String, background: Color, foreground: Color) {
        switch snapshot.connectionState {
        case .connected:
            return ("Connected", Theme.pillConnectedBg.swiftUIColor, DepletionLevel.green.rgb.swiftUIColor)
        case .expired:
            return ("Needs sign-in", Theme.pillNeedsBg.swiftUIColor, DepletionLevel.yellow.rgb.swiftUIColor)
        case .notConnected:
            return ("Off", Theme.ringTrack.swiftUIColor, Theme.textMuted.swiftUIColor)
        case .connecting:
            return ("Connecting", Theme.ringTrack.swiftUIColor, Theme.textSecondary.swiftUIColor)
        case .unsupported:
            return ("Not supported", Theme.ringTrack.swiftUIColor, Theme.textMuted.swiftUIColor)
        }
    }

    private var subtitleText: String {
        if !snapshot.connectedVia.isEmpty {
            return snapshot.connectedVia
        }
        switch snapshot.connectionState {
        case .connected: return "Connected"
        case .expired: return "Sign-in expired"
        case .connecting: return "Finish signing in in your browser"
        case .unsupported: return "Sign-in is not yet supported"
        case .notConnected: return "Not connected"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            AccountRingBadge(
                provider: snapshot.provider,
                percent: fullestPercent,
                ringColor: depletionColor,
                isConnected: isConnected
            )

            VStack(alignment: .leading, spacing: 2) {
                titleText
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(fullestPercent.map { "\($0)%" } ?? "")
                .font(Theme.mono(size: 12, weight: .bold))
                .foregroundStyle(depletionColor ?? Theme.ringTrack.swiftUIColor)
                .frame(width: 40, alignment: .trailing)
                .lineLimit(1)

            let pill = pillSpec
            Text(pill.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(pill.foreground)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .frame(minWidth: 100)
                .background(
                    Capsule()
                        .fill(pill.background)
                )

            actionButton
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    private var titleText: Text {
        if snapshot.plan.isEmpty || snapshot.connectionState == .notConnected {
            return Text(snapshot.provider.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.swiftUIColor)
        }
        return Text(snapshot.provider.displayName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary.swiftUIColor)
        + Text(" \(snapshot.plan)")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Theme.textMuted.swiftUIColor)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch snapshot.connectionState {
        case .connected:
            Button(action: onSignOut) {
                Text("Sign out")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary.swiftUIColor)
                    .frame(width: 104, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.dashedBorder.swiftUIColor, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)

        case .connecting:
            HStack(spacing: 6) {
                AccountSpinnerView(isStaticSnapshot: isStaticSnapshot)
                Text("Waiting")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
            }
            .frame(width: 104, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.selectedBackground.swiftUIColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.dashedBorder.swiftUIColor, lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Waiting")
            .accessibilityAddTraits(.isButton)

        case .expired:
            Button(action: onSignIn) {
                Text("Reconnect")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.neutralButtonText.swiftUIColor)
                    .frame(width: 104, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.neutralButtonFill.swiftUIColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.neutralButtonFill.swiftUIColor, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)

        case .notConnected, .unsupported:
            Button(action: onSignIn) {
                Text("Sign in")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.neutralButtonText.swiftUIColor)
                    .frame(width: 104, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.neutralButtonFill.swiftUIColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.neutralButtonFill.swiftUIColor, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct AccountRingBadge: View {
    let provider: ProviderID
    let percent: Int?
    let ringColor: Color?
    let isConnected: Bool

    var body: some View {
        ZStack {
            if isConnected {
                // Connected: 40x40 container, r=16 (centerline diameter 32, outer 36), stroke width 4
                Circle()
                    .stroke(Theme.ringTrack.swiftUIColor, lineWidth: 4)
                    .frame(width: 32, height: 32)

                if let percent, let ringColor, percent > 0 {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(100, max(0, percent))) / 100.0)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 32, height: 32)
                }
            } else {
                // Inactive: 40 pt outer ring with 4 pt inset stroke (matches still 06)
                Circle()
                    .strokeBorder(Theme.ringTrack.swiftUIColor, lineWidth: 4)
                    .frame(width: 40, height: 40)
            }

            ProviderLogoShape(provider: provider)
                .fill(isConnected ? Theme.textPrimary.swiftUIColor : Theme.dimmedIcon.swiftUIColor)
                .frame(width: 15, height: 15)
        }
        .frame(width: 40, height: 40)
    }
}

private struct AccountSpinnerView: View {
    let isStaticSnapshot: Bool
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(
                    Theme.textSecondary.swiftUIColor,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .rotationEffect(.degrees(isStaticSnapshot ? -45 : angle))
        }
        .frame(width: 11, height: 11)
        .onAppear {
            guard !isStaticSnapshot else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}

// MARK: - Local Tool Checkbox Row

private struct LocalToolCheckboxRow: View {
    let source: LocalToolSource
    let isChecked: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    if isChecked {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.checkboxBlue.swiftUIColor)
                        CheckmarkShape()
                            .stroke(
                                Color.white,
                                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 10, height: 10)
                    } else {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.checkboxBorder.swiftUIColor, lineWidth: 1.5)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(source.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.swiftUIColor)
                        .lineLimit(1)

                    Text(source.pathLabel)
                        .font(Theme.mono(size: 11, weight: .regular))
                        .foregroundStyle(Theme.textMuted.swiftUIColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(source.displayName), \(source.pathLabel)")
        .accessibilityValue(isChecked ? "On" : "Off")
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 10.0
        let sy = rect.height / 10.0
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2.0 * sx, y: rect.minY + 5.2 * sy))
        path.addLine(to: CGPoint(x: rect.minX + 4.0 * sx, y: rect.minY + 7.2 * sy))
        path.addLine(to: CGPoint(x: rect.minX + 8.0 * sx, y: rect.minY + 2.8 * sy))
        return path
    }
}

// MARK: - Editable Threshold Percent Field

private struct ThresholdPercentField: View {
    let value: Int
    let accessibilityLabel: String
    let onApply: (String) -> Bool

    @State private var isEditing = false
    @State private var draft: String
    @State private var valueBeforeEdit: Int
    @FocusState private var isIdleFocused: Bool
    @FocusState private var isTextFieldFocused: Bool

    init(
        value: Int,
        accessibilityLabel: String,
        onApply: @escaping (String) -> Bool
    ) {
        self.value = value
        self.accessibilityLabel = accessibilityLabel
        self.onApply = onApply
        _draft = State(initialValue: "\(value)")
        _valueBeforeEdit = State(initialValue: value)
    }

    var body: some View {
        Group {
            if isEditing {
                editingField
            } else {
                idleField
            }
        }
        .onChange(of: value) { _, newValue in
            if !isEditing {
                draft = "\(newValue)"
                valueBeforeEdit = newValue
            }
        }
    }

    /// Pure SwiftUI idle presentation used identically at launch and in headless `ImageRenderer` snapshots.
    private var idleField: some View {
        Text("\(value)%")
            .font(Theme.mono(size: 12, weight: .regular))
            .foregroundStyle(Theme.textPrimary.swiftUIColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(minWidth: 37, minHeight: 24, maxHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.selectedBackground.swiftUIColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isIdleFocused ? Theme.selectedBorder.swiftUIColor : Theme.dashedBorder.swiftUIColor,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .focusable(true)
            .focusEffectDisabled()
            .focused($isIdleFocused)
            .onTapGesture {
                beginEditing()
            }
            .onKeyPress(.return) {
                beginEditing()
                return .handled
            }
            .onKeyPress(.space) {
                beginEditing()
                return .handled
            }
            .onKeyPress(characters: .decimalDigits) { press in
                beginEditing(initialText: press.characters)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("\(value)%")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                beginEditing()
            }
    }

    /// Real `TextField` swapped in only while editing, committing on Return/blur and reverting invalid input.
    private var editingField: some View {
        HStack(spacing: 0) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.mono(size: 12, weight: .regular))
                .foregroundStyle(Theme.textPrimary.swiftUIColor)
                .multilineTextAlignment(.trailing)
                .frame(width: 20)
                .focused($isTextFieldFocused)
                .accessibilityLabel(accessibilityLabel)
                .onSubmit {
                    commitAndEndEditing(restoreIdleFocus: true)
                }
                .onExitCommand {
                    cancelAndEndEditing(restoreIdleFocus: true)
                }
                .onChange(of: draft) { _, newValue in
                    // Apply live whenever the current text is valid so all screens recolor immediately.
                    _ = onApply(newValue)
                }
                .onChange(of: isTextFieldFocused) { _, focused in
                    if !focused && isEditing {
                        commitAndEndEditing(restoreIdleFocus: false)
                    }
                }

            Text("%")
                .font(Theme.mono(size: 12, weight: .regular))
                .foregroundStyle(Theme.textPrimary.swiftUIColor)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(minWidth: 37, minHeight: 24, maxHeight: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.selectedBackground.swiftUIColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.selectedBorder.swiftUIColor, lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
    }

    private func beginEditing(initialText: String? = nil) {
        valueBeforeEdit = value
        draft = initialText ?? "\(value)"
        isEditing = true
        if let initialText {
            _ = onApply(initialText)
        }
    }

    private func commitAndEndEditing(restoreIdleFocus: Bool) {
        guard isEditing else { return }
        if onApply(draft), let parsed = ThresholdSettings.parsePercentInput(draft) {
            draft = "\(parsed)"
            valueBeforeEdit = parsed
        } else {
            _ = onApply("\(valueBeforeEdit)")
            draft = "\(valueBeforeEdit)"
        }
        isTextFieldFocused = false
        isEditing = false
        if restoreIdleFocus {
            DispatchQueue.main.async {
                isIdleFocused = true
            }
        }
    }

    private func cancelAndEndEditing(restoreIdleFocus: Bool) {
        guard isEditing else { return }
        _ = onApply("\(valueBeforeEdit)")
        draft = "\(valueBeforeEdit)"
        isTextFieldFocused = false
        isEditing = false
        if restoreIdleFocus {
            DispatchQueue.main.async {
                isIdleFocused = true
            }
        }
    }
}
