import AppKit
import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.44, green: 0.91, blue: 0.95)
    static let violet = Color(red: 0.53, green: 0.46, blue: 1.00)
    static let healthy = Color(red: 0.33, green: 0.90, blue: 0.65)
    static let warning = Color(red: 0.95, green: 0.79, blue: 0.44)
    static let danger = Color(red: 1.00, green: 0.51, blue: 0.56)

    static let obsidian = Color(red: 0.025, green: 0.035, blue: 0.09)
    static let cardSurface = Color(red: 0.105, green: 0.085, blue: 0.18).opacity(0.96)
    static let recessedSurface = Color.white.opacity(0.065)

    static let glassWash = LinearGradient(
        colors: [
            Color.white.opacity(0.15),
            Color(red: 0.48, green: 0.34, blue: 0.76).opacity(0.09),
            Color(red: 0.20, green: 0.72, blue: 0.85).opacity(0.035),
            Color.black.opacity(0.08)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 18
        static let control: CGFloat = 11
    }

    enum Motion {
        static let selection = Animation.spring(response: 0.26, dampingFraction: 0.86)
        static let sectionSweep = Animation.easeOut(duration: 0.32)
        static let pageEntrance = Animation.spring(response: 0.34, dampingFraction: 0.92)
        static let pageExit = Animation.easeIn(duration: 0.13)
        static let layeredEntrance = Animation.spring(response: 0.32, dampingFraction: 0.92)
        static let chartDraw = Animation.easeOut(duration: 0.56)
        static let hover = Animation.easeOut(duration: 0.16)
        static let scanReveal = Animation.spring(response: 0.38, dampingFraction: 0.90)
        static let completion = Animation.spring(response: 0.46, dampingFraction: 0.84)
    }
}

struct AuroraBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.08, blue: 0.17),
                        AppTheme.obsidian
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if !reduceTransparency {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [AppTheme.violet.opacity(0.25), AppTheme.violet.opacity(0.08), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: proxy.size.width * 0.35
                            )
                        )
                        .frame(width: proxy.size.width * 0.70, height: proxy.size.height * 0.72)
                        .offset(
                            x: proxy.size.width * 0.29,
                            y: -proxy.size.height * 0.17
                        )

                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [AppTheme.accent.opacity(0.11), AppTheme.accent.opacity(0.035), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: proxy.size.width * 0.30
                            )
                        )
                        .frame(width: proxy.size.width * 0.60, height: proxy.size.height * 0.66)
                        .offset(
                            x: -proxy.size.width * 0.24,
                            y: proxy.size.height * 0.28
                        )

                }
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LiquidGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

/// Keeps the essential takeaway visible while preserving the complete
/// explanation one click away. Use this for background, boundaries, and
/// verification details—not for errors or facts required before an action.
struct InformationDisclosure<Content: View>: View {
    let title: String
    let summary: String
    let symbol: String
    let tint: Color
    let content: Content

    @State private var isExpanded: Bool

    init(
        title: String,
        summary: String,
        symbol: String = "info.circle",
        tint: Color = AppTheme.accent,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.tint = tint
        self.content = content()
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Divider()
                content
            }
            .padding(.top, AppTheme.Spacing.sm)
        } label: {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(
            AppTheme.recessedSurface,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
        )
        .accessibilityHint(isExpanded ? "收起完整说明" : "展开查看完整说明")
    }
}

private struct LiquidGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let padding: CGFloat
    let radius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let padded = content.padding(padding)

        if #available(macOS 26.0, *), !reduceTransparency {
            padded
                .glassEffect(
                    .clear.tint((tint ?? AppTheme.violet).opacity(0.085)).interactive(interactive),
                    in: shape
                )
                .overlay {
                    shape
                        .fill(AppTheme.glassWash)
                        .opacity(0.16)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                .overlay(glassEdge(shape: shape))
                .shadow(color: .black.opacity(0.22), radius: 16, y: 9)
        } else {
            padded
                .background(reduceTransparency ? AnyShapeStyle(AppTheme.cardSurface) : AnyShapeStyle(.ultraThinMaterial), in: shape)
                .overlay {
                    shape
                        .fill(AppTheme.glassWash)
                        .opacity(reduceTransparency ? 0.34 : 0.52)
                        .allowsHitTesting(false)
                }
                .overlay(glassEdge(shape: shape))
                .shadow(color: .black.opacity(0.24), radius: 22, y: 12)
        }
    }

    private func glassEdge(shape: RoundedRectangle) -> some View {
        shape
            .stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(0.40),
                        .white.opacity(0.075),
                        AppTheme.accent.opacity(0.15),
                        .white.opacity(0.045)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.30), AppTheme.accent.opacity(0.12), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 108, height: 1)
                    .padding(.leading, 18)
                    .padding(.top, 1)
            }
            .allowsHitTesting(false)
    }
}

private struct GlassHoverEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(enabled && isHovering && !reduceMotion ? 1.003 : 1)
            .brightness(enabled && isHovering ? 0.018 : 0)
            .animation(reduceMotion ? .linear(duration: 0.01) : AppTheme.Motion.hover, value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

private struct LayeredEntrance: ViewModifier {
    let index: Int
    let isPresented: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .scaleEffect(isPresented ? 1 : 0.98, anchor: .top)
            .offset(y: isPresented ? 0 : 6)
            .animation(
                reduceMotion
                    ? .linear(duration: 0.01)
                    : AppTheme.Motion.layeredEntrance.delay(Double(index) * 0.05),
                value: isPresented
            )
    }
}

struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.liquidGlassSurface()
    }
}

extension View {
    func liquidGlassSurface(
        padding: CGFloat = AppTheme.Spacing.lg,
        radius: CGFloat = AppTheme.Radius.card,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassSurface(padding: padding, radius: radius, tint: tint, interactive: interactive))
    }

    func cardSurface() -> some View {
        modifier(CardSurface())
    }

    func glassHoverEffect(enabled: Bool = true) -> some View {
        modifier(GlassHoverEffect(enabled: enabled))
    }

    func layeredEntrance(index: Int, isPresented: Bool, reduceMotion: Bool) -> some View {
        modifier(LayeredEntrance(index: index, isPresented: isPresented, reduceMotion: reduceMotion))
    }
}
