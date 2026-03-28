import SwiftUI
import API2FileCore

enum IOSTheme {
    static let accent = Color(uiColor: .systemBlue)
    static let accentSecondary = Color(red: 0.32, green: 0.56, blue: 0.97)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardStroke = Color.black.opacity(0.05)

    static let backgroundGradient = LinearGradient(
        colors: [
            Color(uiColor: .systemGroupedBackground),
            Color(uiColor: .secondarySystemGroupedBackground),
            Color(red: 0.90, green: 0.95, blue: 1.00),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let heroGradient = LinearGradient(
        colors: [
            accent.opacity(0.96),
            accentSecondary.opacity(0.88),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let contentTopInset: CGFloat = 10
    static let contentBottomInset: CGFloat = 112
    static let compactHeroSpacing: CGFloat = 16
    static let compactHorizontalInset: CGFloat = 12
    static let regularHorizontalInset: CGFloat = 20
}

struct IOSScreenBackground: View {
    var body: some View {
        ZStack {
            IOSTheme.backgroundGradient

            Circle()
                .fill(IOSTheme.accent.opacity(0.10))
                .frame(width: 420, height: 420)
                .blur(radius: 72)
                .offset(x: 180, y: -260)

            Circle()
                .fill(IOSTheme.accentSecondary.opacity(0.08))
                .frame(width: 300, height: 300)
                .blur(radius: 64)
                .offset(x: -140, y: -120)

            Circle()
                .fill(IOSTheme.accent.opacity(0.06))
                .frame(width: 240, height: 240)
                .blur(radius: 70)
                .offset(x: -120, y: 360)
        }
        .ignoresSafeArea()
    }
}

struct IOSHeroCard<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(horizontalSizeClass == .compact ? 18 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IOSTheme.heroGradient, in: RoundedRectangle(cornerRadius: horizontalSizeClass == .compact ? 20 : 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: horizontalSizeClass == .compact ? 20 : 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: IOSTheme.accent.opacity(0.10), radius: 18, y: 8)
    }
}

struct IOSSectionTitle: View {
    let eyebrow: String?
    let title: String
    let detail: String?

    init(_ title: String, eyebrow: String? = nil, detail: String? = nil) {
        self.title = title
        self.eyebrow = eyebrow
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IOSTheme.textSecondary)
                    .tracking(1.2)
            }

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(IOSTheme.textPrimary)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(IOSTheme.textSecondary)
            }
        }
    }
}

struct IOSMetricTile: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(horizontalSizeClass == .compact ? .title3.weight(.bold) : .headline.weight(.semibold))
                    .foregroundStyle(IOSTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(IOSTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: horizontalSizeClass == .compact ? 104 : 94, alignment: .topLeading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
    }
}

struct IOSMetricBadge: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(IOSTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(IOSTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }
}

struct IOSStatusPill: View {
    let title: String
    let tint: Color

    init(title: String, tint: Color) {
        self.title = title
        self.tint = tint
    }

    init(status: ServiceStatus) {
        switch status {
        case .connected:
            self.title = "Ready"
            self.tint = IOSTheme.success
        case .syncing:
            self.title = "Syncing"
            self.tint = IOSTheme.accent
        case .paused:
            self.title = "Paused"
            self.tint = IOSTheme.warning
        case .error:
            self.title = "Needs Attention"
            self.tint = IOSTheme.danger
        case .disconnected:
            self.title = "Offline"
            self.tint = Color.white.opacity(0.55)
        }
    }

    init(outcome: SyncOutcome) {
        switch outcome {
        case .success:
            self.title = "Success"
            self.tint = IOSTheme.success
        case .error:
            self.title = "Error"
            self.tint = IOSTheme.danger
        case .conflict:
            self.title = "Conflict"
            self.tint = IOSTheme.warning
        }
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.opacity(0.24), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.36), lineWidth: 1)
            }
    }
}

struct IOSSecondaryPill: View {
    let title: String
    let systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(IOSTheme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: Capsule())
    }
}

struct IOSEmptyStateCard: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        message: String,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(IOSTheme.textPrimary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(IOSTheme.textSecondary)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(IOSProminentButtonStyle())
            }
        }
        .iosCardStyle()
    }
}

struct IOSProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [
                        IOSTheme.accent.opacity(configuration.isPressed ? 0.72 : 0.96),
                        IOSTheme.accentSecondary.opacity(configuration.isPressed ? 0.62 : 0.88),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

struct IOSOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(IOSTheme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(IOSTheme.accent.opacity(configuration.isPressed ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(IOSTheme.accent.opacity(0.16), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder
    func iosCardStyle(cornerRadius: CGFloat = 28, contentPadding: CGFloat = 20) -> some View {
        let compactCornerRadius = max(18, cornerRadius - 6)

        modifier(
            IOSCardModifier(
                cornerRadius: cornerRadius,
                compactCornerRadius: compactCornerRadius,
                contentPadding: contentPadding
            )
        )
    }

    func iosScreenBackground() -> some View {
        background(Color.clear)
    }
}

private struct IOSCardModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let cornerRadius: CGFloat
    let compactCornerRadius: CGFloat
    let contentPadding: CGFloat

    func body(content: Content) -> some View {
        let resolvedCornerRadius = horizontalSizeClass == .compact ? compactCornerRadius : cornerRadius
        let resolvedPadding = horizontalSizeClass == .compact ? max(16, contentPadding - 2) : contentPadding
        let shape = RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)

        content
            .padding(resolvedPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(IOSTheme.cardBackground))
            .overlay {
                shape.strokeBorder(IOSTheme.cardStroke, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.03), radius: 8, y: 3)
    }
}
