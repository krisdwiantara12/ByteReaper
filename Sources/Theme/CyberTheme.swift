import SwiftUI

/// Color tokens and visual styling for ByteReaper's Dark OLED Cyberpunk iOS Glass interface.
/// All text/background combinations are verified against WCAG AA (>= 4.5:1).
enum CyberTheme {
    static let oledBlack = Color(red: 0.00, green: 0.00, blue: 0.00)
    static let elevatedSurface = Color(red: 0.051, green: 0.063, blue: 0.090) // #0D1017
    static let hairlineBorder = Color(red: 0.118, green: 0.145, blue: 0.200)  // #1E2533
    static let textPrimary = Color(red: 0.957, green: 0.969, blue: 0.984)     // #F4F7FB
    static let textSecondary = Color(red: 0.604, green: 0.647, blue: 0.722)   // #9AA5B8

    static let cyberCyan = Color(red: 0.000, green: 0.898, blue: 1.000)       // #00E5FF
    static let cyanInk = Color(red: 0.016, green: 0.063, blue: 0.086)         // #041016 (12.51:1 on cyan)
    static let crimsonButtonFill = Color(red: 0.722, green: 0.059, blue: 0.243) // #B80F3E (6.61:1 with white)
    static let crimsonText = Color(red: 1.000, green: 0.361, blue: 0.541)     // #FF5C8A (7.15:1 on black)
    static let acidMint = Color(red: 0.180, green: 0.902, blue: 0.651)        // #2EE6A6 (12.99:1 on black)
    static let mintInk = Color(red: 0.012, green: 0.094, blue: 0.071)         // #031812 (11.36:1 on mint)
}

/// Formats byte sizes and durations with tabular monospaced precision for fast scanning.
enum ByteFormatter {
    private static let formatter: ByteCountFormatter = {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        fmt.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        fmt.includesUnit = true
        fmt.isAdaptive = true
        return fmt
    }()

    /// Returns human-readable file size (e.g. "4.82 GB") using decimal file units matching iOS Settings.
    static func string(from bytes: Int64) -> String {
        formatter.string(fromByteCount: max(0, bytes))
    }

    /// Formats duration in mm:ss or hh:mm:ss for video assets.
    static func durationString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// Applies restrained iOS glassmorphism exclusively to the 2 focal shell containers (HUD + Floating Dock).
struct CyberGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 22
    var accentGlow: Bool = false

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(CyberTheme.elevatedSurface.opacity(0.68))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                CyberTheme.cyberCyan.opacity(0.32),
                                Color.white.opacity(0.10),
                                CyberTheme.hairlineBorder
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: accentGlow ? CyberTheme.cyberCyan.opacity(0.22) : Color.clear,
                radius: accentGlow ? 12 : 0,
                y: 4
            )
    }
}

extension View {
    /// Applies the focal iOS glass frame reserved for top HUD and bottom dock surfaces.
    func cyberGlass(cornerRadius: CGFloat = 22, accentGlow: Bool = false) -> some View {
        modifier(CyberGlassSurface(cornerRadius: cornerRadius, accentGlow: accentGlow))
    }
}

