import AppKit
import OpenUsageCore
import SwiftUI

struct PlaceholderPopoverView: View {
    let store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)
                Spacer()
                Text(store.options.isDemo ? "Demo mode" : "Not connected")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted.swiftUIColor)
            }

            if store.snapshots.allSatisfy({ $0.connectionState == .notConnected || $0.connectionState == .unsupported }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No accounts connected")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.swiftUIColor)
                    Text("Connect a subscription in Accounts to see live usage limits.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted.swiftUIColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.cardBackground.swiftUIColor, in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 8) {
                    ForEach(store.snapshots) { snapshot in
                        HStack(spacing: 10) {
                            ProviderLogoShape(provider: snapshot.provider)
                                .fill(snapshot.connectionState == .connected ? Theme.textPrimary.swiftUIColor : Theme.textMuted.swiftUIColor)
                                .frame(width: 14, height: 14)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.provider.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary.swiftUIColor)
                                Text(snapshot.connectedVia)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                            }

                            Spacer()

                            switch snapshot.menuBarEntryState {
                            case .connected(let percent):
                                let level = store.thresholds.level(for: percent)
                                Text("\(percent)%")
                                    .font(Theme.mono(size: 12, weight: .bold))
                                    .foregroundStyle(level.rgb.swiftUIColor)
                            case .dimmedPlaceholder, .omitted:
                                Text("--")
                                    .font(Theme.mono(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.textMuted.swiftUIColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.cardBackground.swiftUIColor, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary.swiftUIColor)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(Theme.background.swiftUIColor)
        .preferredColorScheme(.dark)
        .task {
            await store.refresh()
        }
    }
}
