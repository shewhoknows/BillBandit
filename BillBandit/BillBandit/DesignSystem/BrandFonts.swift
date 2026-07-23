import SwiftUI

/// Brand typography — bundled TTFs (SIL OFL), registered via UIAppFonts.
/// PostScript names verified against the bundled files.
enum BrandFont {
    /// The original mockup values read too small on physical iPhones. Keep one
    /// proportional scale here so every screen grows consistently and still
    /// participates in Dynamic Type through the relative text styles below.
    static let scale: CGFloat = 1.15

    enum Weight {
        case regular, medium, semibold, bold, extraBold
    }

    /// Fredoka — chunky display: wordmark, big numbers, buttons
    static func display(_ size: CGFloat, weight: Weight = .semibold) -> Font {
        .custom(fredoka(weight), size: size * scale, relativeTo: .title)
    }

    /// Caveat — handwritten accents ("you're owed overall", captions)
    static func hand(_ size: CGFloat, weight: Weight = .semibold) -> Font {
        .custom(caveat(weight), size: size * scale, relativeTo: .title3)
    }

    /// Courier Prime — typewriter ledger: invoice lines, activity rows, stamps
    static func type(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "CourierPrime-Bold" : "CourierPrime-Regular", size: size * scale, relativeTo: .body)
    }

    /// Nunito — UI body text
    static func body(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .custom(nunito(weight), size: size * scale, relativeTo: .body)
    }

    // MARK: PostScript names of the bundled TTFs

    private static func fredoka(_ w: Weight) -> String {
        switch w {
        case .regular:             return "Fredoka-Regular"
        case .medium:              return "Fredoka-Medium"
        case .semibold:            return "Fredoka-SemiBold"
        case .bold, .extraBold:    return "Fredoka-Bold"
        }
    }

    private static func caveat(_ w: Weight) -> String {
        switch w {
        case .regular, .medium:    return "Caveat-Medium"
        case .semibold:            return "Caveat-SemiBold"
        case .bold, .extraBold:    return "Caveat-Bold"
        }
    }

    private static func nunito(_ w: Weight) -> String {
        switch w {
        case .regular:             return "Nunito-Regular"
        case .medium:              return "Nunito-SemiBold"
        case .semibold:            return "Nunito-SemiBold"
        case .bold:                return "Nunito-Bold"
        case .extraBold:           return "Nunito-ExtraBold"
        }
    }
}
