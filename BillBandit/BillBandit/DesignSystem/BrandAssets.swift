import SwiftUI

/// Shared timing keeps BillBandit's motion feeling like one system. Continuous
/// movement is intentionally slower than interaction feedback.
enum BrandMotion {
    static let quick = Animation.easeOut(duration: 0.18)
    static let pageSpring = Animation.spring(response: 0.62, dampingFraction: 0.88)
    static let revealSpring = Animation.spring(response: 0.48, dampingFraction: 0.78)
    static let progressReveal = Animation.spring(response: 0.62, dampingFraction: 0.92,
                                                  blendDuration: 0.14)
    static let expenseReveal = Animation.spring(response: 0.82, dampingFraction: 0.84)
    static let counter = Animation.easeOut(duration: 0.72)

    static func page(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.16) : pageSpring
    }

    static func reveal(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : revealSpring
    }
}

/// BillBandit's outline contract. Pill, capsule and rounded control surfaces
/// use an inset `strokeBorder` at this width so the visible keyline never varies
/// because half of a centred stroke was clipped by its container.
enum BrandOutline {
    static let control: CGFloat = 2.5
    static let badge: CGFloat = 3
}

/// Presentation-only queue for reward feedback after branded sheets dismiss.
/// Persistent progress remains entirely in SwiftData via RewardEngine.
@MainActor
final class RewardFeedbackCenter: ObservableObject {
    static let shared = RewardFeedbackCenter()

    @Published private(set) var current: RewardOutcome?
    private var presentationTask: Task<Void, Never>?

    func present(_ outcome: RewardOutcome, after delay: TimeInterval = 0.4) {
        presentationTask?.cancel()
        presentationTask = Task { [weak self] in
            let delayNanos = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }
            self?.current = outcome
            let visibleNanos: UInt64 = outcome.unlockedAchievements.isEmpty
                ? 2_400_000_000 : 3_200_000_000
            try? await Task.sleep(nanoseconds: visibleNanos)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

/// The six official mascot poses (source: BillBandit-Raccoon-SVG/*.svg,
/// converted to vector PDFs — colours untouched).
enum Mascot: String, CaseIterable {
    case greeting, thinking, confused, celebrating, neutral, grumpy

    var image: Image { Image("mascot-\(rawValue)") }
}

/// Contextual two-colour mascot scenes supplied separately from the six core
/// character poses. They retain their original wide 1600×1280 composition.
enum MascotScene: String, CaseIterable {
    case bill, overdue, searching, sleepy

    var image: Image { Image("mascot-scene-\(rawValue)") }
}

/// Hand-drawn icon set (same artwork as the mockup board, template-tinted).
enum BrandIcon: String {
    case home, users, plus, pulse, user, bell, search, x, chevL, cam
    case pizza, coffee, car, plane, cart, gift, house, receipti, gear

    var image: Image { Image("icon-\(rawValue)") }
}

extension Image {
    init(mascot: Mascot) { self = mascot.image }
    init(mascotScene: MascotScene) { self = mascotScene.image }
    init(icon: BrandIcon) { self = icon.image }
    init(profileAvatar: ProfileAvatar) { self = Image("avatar-\(profileAvatar.rawValue)") }
}

/// Reusable profile identity shown in the picker, friend ledger, tab bar and
/// dashboard. The source artwork's loose inner ring is cropped away so every
/// placement gets one crisp, perfectly centred app-owned outline.
struct ProfileAvatarView: View {
    let avatar: ProfileAvatar
    var size: CGFloat = 52
    var isSelected = false

    var body: some View {
        Image(profileAvatar: avatar)
            .interpolation(.high)
            .resizable()
            .scaledToFill()
            .frame(width: size * 1.22, height: size * 1.22)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(
                Color.Brand.cobalt,
                lineWidth: isSelected ? max(3.5, size * 0.026) : max(2, size * 0.018)
            ))
            .contentShape(Circle())
            .accessibilityHidden(true)
    }
}

/// One canonical achievement crop for Profile pins, unlock toasts and any
/// future achievement presentation. The source keyline is enlarged beneath the
/// mask, leaving the app-owned ring completely flush with the artwork.
struct AchievementBadgeView: View {
    let achievement: StarterAchievement
    var isUnlocked = true
    var size: CGFloat = 78

    var body: some View {
        Image(achievement.assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .scaleEffect(1.30)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .saturation(isUnlocked ? 1 : 0)
            .opacity(isUnlocked ? 1 : 0.34)
            .overlay {
                Circle()
                    .strokeBorder(Color.Brand.cobalt.opacity(isUnlocked ? 1 : 0.34),
                                  lineWidth: BrandOutline.badge)
            }
    }
}

/// Icon styled the way the mockups draw them: single-colour, slightly chubby.
struct BrandIconView: View {
    let icon: BrandIcon
    var size: CGFloat = 22

    var body: some View {
        Image(icon: icon)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

/// Mascot sized to fit, preserving the square 1280 art.
struct MascotView: View {
    let mascot: Mascot
    var size: CGFloat = 160
    var idle = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var idlePhase = false

    var body: some View {
        Image(mascot: mascot)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(idle && !reduceMotion ? (idlePhase ? 1.012 : 0.995) : 1, anchor: .bottom)
            .rotationEffect(.degrees(idle && !reduceMotion ? idleRotation : 0), anchor: .bottom)
            .offset(y: idle && !reduceMotion ? (idlePhase ? -3 : 2) : 0)
            .animation(idleAnimation, value: idlePhase)
            .accessibilityLabel("BillBandit raccoon — \(mascot.rawValue)")
            .onAppear { idlePhase = idle && !reduceMotion }
            .onChange(of: reduceMotion) {
                idlePhase = idle && !reduceMotion
            }
            .onDisappear { idlePhase = false }
    }

    private var idleRotation: Double {
        let amount: Double
        switch mascot {
        case .greeting: amount = 1.1
        case .thinking: amount = -0.8
        case .confused: amount = 0.7
        case .celebrating: amount = 0.9
        case .neutral: amount = 0.35
        case .grumpy: amount = -0.45
        }
        return idlePhase ? amount : -amount
    }

    private var idleAnimation: Animation? {
        guard idle, !reduceMotion else { return nil }
        let duration: Double = mascot == .greeting ? 2.2 : 2.65
        return .easeInOut(duration: duration).repeatForever(autoreverses: true)
    }
}

/// Static scene renderer; contextual animation belongs to the screen that owns
/// the scene so each movement has a clear product meaning.
struct MascotSceneView: View {
    let scene: MascotScene
    var width: CGFloat = 290

    var body: some View {
        Image(mascotScene: scene)
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .accessibilityLabel("BillBandit raccoon scene — \(scene.rawValue)")
    }
}

/// Product-ready thinking pose with a quiet double blink and small eye dart.
/// The artwork remains the supplied vector; only the eye layer is articulated.
struct ThinkingBlinkMascotView: View {
    var size: CGFloat = 88

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: 4.8)
            let blink = max(Self.pulse(phase, center: 0.72, width: 0.11),
                            Self.pulse(phase, center: 0.96, width: 0.09))
            let dart = Self.eyeDart(phase)

            ZStack {
                MascotView(mascot: .thinking, size: size, idle: false)

                HStack(spacing: size * 0.052) {
                    articulatedEye(blink: blink, dart: dart)
                    articulatedEye(blink: blink, dart: dart)
                }
                .offset(x: -size * 0.001, y: -size * 0.304)
                .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("BillBandit thinking raccoon, blinking")
    }

    private func articulatedEye(blink: Double, dart: Double) -> some View {
        let eyeSize = size * 0.057
        return ZStack {
            Circle()
                .fill(Color.Brand.creamSoft)
                .frame(width: eyeSize, height: eyeSize)
            Circle()
                .fill(Color.Brand.cobalt)
                .frame(width: size * 0.015, height: size * 0.015)
                .offset(x: CGFloat(dart) * size * 0.012)
            ZStack {
                Capsule()
                    .fill(Color.Brand.cobalt)
                    .frame(width: size * 0.066, height: size * 0.055)
                Capsule()
                    .fill(Color.Brand.creamSoft)
                    .frame(width: size * 0.044,
                           height: max(1, size * 0.014 * (1 - blink)))
            }
            .opacity(blink)
        }
        .frame(width: eyeSize, height: eyeSize)
    }

    private static func pulse(_ value: Double, center: Double, width: Double) -> Double {
        max(0, 1 - abs(value - center) / width)
    }

    private static func eyeDart(_ phase: Double) -> Double {
        guard phase >= 2.35, phase <= 3.35 else { return 0 }
        let progress = (phase - 2.35) / 1.0
        return sin(progress * .pi)
    }
}

/// A slow sleeping scene for quiet empty states. Reduce Motion keeps the supplied
/// scene completely static while retaining the original drawn Zs.
struct SleepingMascotSceneView: View {
    var width: CGFloat = 230

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let breath = reduceMotion ? 0 : (sin(time * 1.35) + 1) / 2

            ZStack {
                MascotSceneView(scene: .sleepy, width: width)
                    .scaleEffect(x: 1 + breath * 0.005,
                                 y: 0.994 + breath * 0.014,
                                 anchor: .bottom)
                    .offset(y: -breath * 1.5)

                if !reduceMotion {
                    ForEach(0..<2, id: \.self) { index in
                        let phase = (time * 0.20 + Double(index) * 0.46)
                            .truncatingRemainder(dividingBy: 1)
                        Text("Z")
                            .font(BrandFont.display(10 + CGFloat(index) * 2.5, weight: .bold))
                            .foregroundStyle(Color.Brand.cobalt)
                            .opacity((1 - phase) * 0.72)
                            .offset(x: width * 0.04 + CGFloat(index) * 13 + phase * 13,
                                    y: -width * 0.18 - phase * 38)
                    }
                }
            }
        }
        .frame(width: width, height: width * 0.72)
        .accessibilityLabel("BillBandit raccoon sleeping in an empty group")
    }
}

/// A true interpolating money label: SwiftUI redraws the formatted value for
/// every animation frame rather than only cross-fading the old and new strings.
struct AnimatedCurrencyText: View {
    let amount: Decimal
    let font: Font
    var countsFromZero = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue: Double = 0

    var body: some View {
        Text("")
            .modifier(CurrencyCounterModifier(value: displayedValue, font: font))
            .accessibilityLabel(Money.currency(amount))
            .onAppear {
                if !countsFromZero { displayedValue = targetValue }
                updateValue()
            }
            .onChange(of: amount) { updateValue() }
            .onChange(of: reduceMotion) { updateValue() }
    }

    private var targetValue: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }

    private func updateValue() {
        withAnimation(reduceMotion ? nil : BrandMotion.counter) {
            displayedValue = targetValue
        }
    }
}

private struct CurrencyCounterModifier: AnimatableModifier {
    var value: Double
    let font: Font

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View {
        Text(Money.currency(Decimal(value)))
            .font(font)
            .monospacedDigit()
    }
}
