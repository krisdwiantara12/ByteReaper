import SwiftUI

/// Glass Surface #1 of 2: Pinned top storage telemetry HUD showing real iPhone capacity,
/// purgeable headroom, and total bytes reclaimed in this session.
/// Automatically condenses when `isCompact` is true to maximize list space during scrolling.
struct StorageHUDCard: View {
    let snapshot: DeviceStorageSnapshot
    let reclaimedBytes: Int64
    var allTimeReclaimedBytes: Int64 = 0
    let isScanning: Bool
    var isCompact: Bool = false
    let onRefresh: () -> Void

    private var isCritical: Bool {
        snapshot.usedFraction >= 0.85
    }

    private var barColor: Color {
        isCritical ? CyberTheme.crimsonText : CyberTheme.cyberCyan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if !isCompact {
                        Text("BYTEREAPER")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CyberTheme.cyberCyan)
                            .accessibilityLabel("ByteReaper")
                    }

                    if snapshot.totalBytes > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(ByteFormatter.string(from: snapshot.usedBytes))
                                .font((isCompact ? Font.headline : Font.title2).weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(CyberTheme.textPrimary)

                            Text("dari \(ByteFormatter.string(from: snapshot.totalBytes))")
                                .font(isCompact ? .caption : .subheadline)
                                .monospacedDigit()
                                .foregroundStyle(CyberTheme.textSecondary)
                        }
                    } else {
                        Text("Membaca kapasitas iPhone...")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CyberTheme.textSecondary)
                    }
                }

                Spacer()

                if isCompact && reclaimedBytes > 0 {
                    Text("+\(ByteFormatter.string(from: reclaimedBytes))")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(CyberTheme.mintInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(CyberTheme.acidMint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                Button(action: onRefresh) {
                    Image(systemName: isScanning ? "stop.circle" : "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isScanning ? CyberTheme.crimsonText : CyberTheme.cyberCyan)
                        .frame(width: 44, height: 44)
                        .background(CyberTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                        )
                }
                .accessibilityLabel(isScanning ? "Hentikan pemindaian" : "Muat ulang kapasitas")
            }

            GeometryReader { geo in
                let width = max(0, geo.size.width)
                let fillWidth = max(6, width * snapshot.usedFraction)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(CyberTheme.oledBlack.opacity(0.85))
                        .frame(height: isCompact ? 7 : 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(CyberTheme.hairlineBorder, lineWidth: 1)
                        )

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(barColor)
                        .frame(width: snapshot.totalBytes > 0 ? fillWidth : 0, height: isCompact ? 7 : 10)
                        .shadow(color: barColor.opacity(0.32), radius: 8, x: 0, y: 0)
                        .animation(.easeOut(duration: 0.25), value: snapshot.usedFraction)
                }
            }
            .frame(height: isCompact ? 7 : 10)

            if !isCompact {
                HStack(spacing: 12) {
                    Label {
                        Text("Tersedia \(ByteFormatter.string(from: snapshot.availableImportantBytes))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(CyberTheme.textSecondary)
                    } icon: {
                        Image(systemName: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(CyberTheme.cyberCyan)
                    }

                    Spacer()

                    if reclaimedBytes > 0 {
                        Text("+\(ByteFormatter.string(from: reclaimedBytes)) sesi")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(CyberTheme.mintInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(CyberTheme.acidMint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else if allTimeReclaimedBytes > 0 {
                        Text("Total \(ByteFormatter.string(from: allTimeReclaimedBytes))")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(CyberTheme.mintInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(CyberTheme.acidMint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else if snapshot.purgeableEstimateBytes > 0 {
                        Text("Cache iOS ~\(ByteFormatter.string(from: snapshot.purgeableEstimateBytes))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(CyberTheme.textSecondary)
                    }
                }
            }
        }
        .padding(isCompact ? 12 : 16)
        .cyberGlass(cornerRadius: isCompact ? 18 : 22, accentGlow: false)
        .animation(.easeInOut(duration: 0.2), value: isCompact)
    }
}
