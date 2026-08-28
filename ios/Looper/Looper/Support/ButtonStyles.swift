import SwiftUI

/// Filled CTA button. Mirrors the web app's `.primary` class (56pt tall,
/// 16pt corner radius, bold 16pt label, dark text on the accent fill) —
/// sizing that got lost when these screens were ported to SwiftUI.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 56
    var cornerRadius: CGFloat = 16
    var fontSize: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(Color.looperOnAccent)
            .padding(.horizontal, 16)
            .frame(minHeight: height)
            .background(
                Color.looperAccent.opacity(configuration.isPressed ? 0.85 : 1),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

/// Outlined button. Mirrors the web app's `.secondary` class — same
/// footprint as PrimaryButtonStyle so the two line up when stacked.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 56
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: height)
            // A button's decorative border is not automatically its hit area.
            // Make the entire outlined rectangle tappable, including the space
            // either side of labels such as “Choose on map”.
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.looperLine, lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Floating pill CTA. Mirrors the web app's `.start-fab` (50pt tall, fully
/// rounded, 15pt label) used for the pinned "Start walk" action.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color.looperOnAccent)
            .padding(.horizontal, 22)
            .frame(minHeight: 44)
            .background(
                Color.looperAccent.opacity(configuration.isPressed ? 0.85 : 1),
                in: Capsule()
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

extension IconButtonStyle {
    /// The floating map-chrome look, shared with the map style button, so
    /// the map carries on underneath the controls sitting on it.
    static let glass = IconButtonStyle(
        background: .looperGlass,
        bordered: true,
        shadowed: true,
        border: .looperGlassLine
    )
}

/// Small circular icon button. Mirrors the web app's `.icon-btn` (38x38,
/// `--chrome-btn`) used for map-chrome controls and sheet-head actions.
struct IconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 38
    var background: Color = .looperSheet
    /// Sheet-head icons (e.g. route refresh/reverse) use a hairline border
    /// and no shadow; floating map-chrome icons use a shadow and no border.
    var bordered = false
    /// Sheet-head icons take their shadow from `bordered`; map chrome is
    /// bordered *and* shadowed, so it can say so.
    var shadowed: Bool?
    var border: Color = .looperLine

    func makeBody(configuration: Configuration) -> some View {
        let hasShadow = shadowed ?? !bordered
        return configuration.label
            .font(.system(size: 16, weight: .semibold))
            .frame(width: diameter, height: diameter)
            .background(
                Circle()
                    .fill(background)
                    .overlay(Circle().stroke(border, lineWidth: bordered ? 1 : 0))
            )
            .shadow(color: .black.opacity(hasShadow ? 0.3 : 0), radius: hasShadow ? 10 : 0, y: hasShadow ? 4 : 0)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

/// Small underlined text link. Mirrors the web app's `.text` / `.link` /
/// `.help` classes used for tertiary actions ("Edit", "End walk", etc).
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.looperAccent)
            .underline()
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
