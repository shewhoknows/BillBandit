import SwiftUI
import UIKit

enum BBColor {
    static let blue = adaptive(light: 0x0F45D6, dark: 0x3F6BFF)
    static let cream = adaptive(light: 0xFFF5DE, dark: 0xF4E3BE)
    static let blueDark = adaptive(light: 0x082B8F, dark: 0xC9D5FF)
    static let blueXDark = adaptive(light: 0x071245, dark: 0x071245)
    static let paper = adaptive(light: 0xF7F2DE, dark: 0x2E2618)
    static let success = adaptive(light: 0x1F8F66, dark: 0x53C99A)
    static let danger = adaptive(light: 0xA81F33, dark: 0xF07082)
    static let faded = adaptive(light: 0x54638C, dark: 0xAAB3D0)

    static let plum = adaptive(light: 0x6D47C6, dark: 0x9F83E6)
    static let teal = adaptive(light: 0x1A9BA3, dark: 0x5ECBD0)
    static let coral = adaptive(light: 0xF26B5C, dark: 0xFF958B)
    static let sun = adaptive(light: 0xF4BC3D, dark: 0xFFD66B)
    static let leaf = adaptive(light: 0x3DAB6E, dark: 0x78D99C)

    static let divider = blueDark.opacity(0.20)
    static let receiptBorder = blueDark.opacity(0.28)
    static let fieldBorder = blueDark.opacity(0.26)
    static let chipBorder = blue.opacity(0.28)
    static let shadow = Color.black.opacity(0.08)

    static let background = blue
    static let surface = paper
    static let textPrimary = blueDark
    static let body = blueDark
    static let textFaded = faded
    static let textOnBlue = cream
    static let accent = blue

    static let avatarPalette: [Color] = [plum, teal, coral, sun, leaf]

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(
                hex: traits.userInterfaceStyle == .dark ? dark : light
            )
        })
    }
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum BBFont {
    static func display(size: CGFloat, weight: Font.Weight = .bold, relativeTo textStyle: Font.TextStyle = .title) -> Font {
        scaledSystem(size: size, weight: weight, design: .serif, relativeTo: textStyle)
    }

    static func label(size: CGFloat, weight: Font.Weight = .semibold, relativeTo textStyle: Font.TextStyle = .caption) -> Font {
        scaledSystem(size: size, weight: weight, design: .monospaced, relativeTo: textStyle)
    }

    static func amount(size: CGFloat, weight: Font.Weight = .bold, relativeTo textStyle: Font.TextStyle = .title2) -> Font {
        scaledSystem(size: size, weight: weight, design: .monospaced, relativeTo: textStyle)
    }

    static func body(size: CGFloat = 14, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        scaledSystem(size: size, weight: weight, design: .default, relativeTo: textStyle)
    }

    static func bodyRounded(size: CGFloat = 14, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        scaledSystem(size: size, weight: weight, design: .rounded, relativeTo: textStyle)
    }

    static func handwriting(size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        if let caveat = UIFont(name: "CaveatRoman-Regular", size: size) ?? UIFont(name: "Caveat", size: size) {
            Font(UIFontMetrics(forTextStyle: textStyle.uiTextStyle).scaledFont(for: caveat))
        } else {
            scaledSystem(size: size, weight: .regular, design: .serif, relativeTo: textStyle, italic: true)
        }
    }

    private static func scaledSystem(
        size: CGFloat,
        weight: Font.Weight,
        design: UIFontDescriptor.SystemDesign,
        relativeTo textStyle: Font.TextStyle,
        italic: Bool = false
    ) -> Font {
        let baseFont = UIFont.systemFont(ofSize: size, weight: weight.uiWeight)
        var descriptor = baseFont.fontDescriptor.withDesign(design) ?? baseFont.fontDescriptor

        if italic, let italicDescriptor = descriptor.withSymbolicTraits(.traitItalic) {
            descriptor = italicDescriptor
        }

        let designedFont = UIFont(descriptor: descriptor, size: size)
        let scaledFont = UIFontMetrics(forTextStyle: textStyle.uiTextStyle).scaledFont(for: designedFont)
        return Font(scaledFont)
    }
}

enum BBTracking {
    static let monoLabel: CGFloat = 0.05
    static let sectionLabel: CGFloat = 0.08
    static let stamp: CGFloat = 0.12

    static func value(_ em: CGFloat, for size: CGFloat) -> CGFloat {
        em * size
    }
}

enum BBSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 28
    static let xxxl: CGFloat = 32
    static let huge: CGFloat = 40
    static let giant: CGFloat = 48
    static let jumbo: CGFloat = 64
    static let max: CGFloat = 80
}

enum BBRadius {
    static let stamp: CGFloat = 4
    static let receipt: CGFloat = 8
    static let button: CGFloat = 8
    static let field: CGFloat = 8
    static let tabBar: CGFloat = 12
    static let metricTile: CGFloat = 18
    static let panel: CGFloat = 22
}

enum BBBorder {
    static let receipt = StrokeStyle(lineWidth: 1, dash: [5, 4])
    static let divider = StrokeStyle(lineWidth: 1, dash: [3, 5], dashPhase: 1)
    static let field = StrokeStyle(lineWidth: 1)
    static let stamp = StrokeStyle(lineWidth: 2, dash: [6, 3])
    static let chip = StrokeStyle(lineWidth: 1)
}

enum BBShadow {
    case card
    case tab
    case float

    var color: Color {
        switch self {
        case .card, .tab:
            Color.black.opacity(0.08)
        case .float:
            Color.black.opacity(0.12)
        }
    }

    var radius: CGFloat {
        switch self {
        case .card:
            18
        case .tab:
            14
        case .float:
            12
        }
    }

    var y: CGFloat {
        switch self {
        case .card:
            10
        case .tab:
            6
        case .float:
            4
        }
    }
}

extension View {
    func bbShadow(_ shadow: BBShadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y)
    }
}

private extension Font.Weight {
    var uiWeight: UIFont.Weight {
        switch self {
        case .ultraLight:
            .ultraLight
        case .thin:
            .thin
        case .light:
            .light
        case .regular:
            .regular
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        case .heavy:
            .heavy
        case .black:
            .black
        default:
            .regular
        }
    }
}

private extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle:
            .largeTitle
        case .title:
            .title1
        case .title2:
            .title2
        case .title3:
            .title3
        case .headline:
            .headline
        case .subheadline:
            .subheadline
        case .body:
            .body
        case .callout:
            .callout
        case .footnote:
            .footnote
        case .caption:
            .caption1
        case .caption2:
            .caption2
        default:
            .body
        }
    }
}
