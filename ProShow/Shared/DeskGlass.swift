import SwiftUI

/// Chrome-only Liquid Glass. Never apply to content-layer views (monitors, grids, rundown, audio strips).
struct DeskChromeGlass<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            let glass: Glass = {
                var value = Glass.regular
                if let tint { value = value.tint(tint) }
                if interactive { value = value.interactive() }
                return value
            }()
            content.glassEffect(glass, in: shape)
        } else if reduceTransparency {
            content
                .background(ProShowTheme.panel, in: shape)
                .overlay { shape.stroke(ProShowTheme.hairline, lineWidth: 1) }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(ProShowTheme.hairline, lineWidth: 1) }
        }
    }
}

/// One sampling region for nearby glass shapes on OS 26; a plain stack before that.
struct DeskGlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// One prominent live action. Glass on 26, bordered prominent before.
struct PrimaryLiveStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .tint(ProShowTheme.liveRed)
                .controlSize(.large)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .tint(ProShowTheme.liveRed)
                .controlSize(.large)
        }
    }
}

extension View {
    func deskChromeGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(DeskChromeGlass(shape: shape, tint: tint, interactive: interactive))
    }

    func primaryLiveStyle() -> some View {
        modifier(PrimaryLiveStyle())
    }
}

/// Opaque inspector section card sitting on inspector glass or panel. Never glass.
struct InspectorCard<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DeskSpace.xs) {
                content()
            }
            .padding(.top, DeskSpace.xs)
        } label: {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
        }
        .padding(DeskSpace.sm)
        .background(ProShowTheme.well, in: RoundedRectangle(cornerRadius: DeskRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeskRadius.card, style: .continuous)
                .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
        }
        .controlSize(.small)
    }
}
