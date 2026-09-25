import SwiftUI

/// Audience / program surface — full-bleed lyrics on a dark stage.
struct AudienceView: View {
    let slide: Slide?
    var showsChrome: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    ProShowTheme.stageBlack,
                    ProShowTheme.stageInk,
                    Color(red: 0.10, green: 0.08, blue: 0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Soft vignette / atmosphere (not a card)
            RadialGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color.clear,
                ],
                center: .center,
                startRadius: 40,
                endRadius: 480
            )
            .ignoresSafeArea()

            if let slide, !slide.isBlank, !slide.displayText.isEmpty {
                Text(slide.displayText)
                    .font(.system(size: 56, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ProShowTheme.lyricWhite)
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 32)
                    .minimumScaleFactor(0.35)
                    .lineLimit(8)
                    .frame(maxWidth: 1100)
            } else {
                Color.clear
            }

            if showsChrome {
                VStack {
                    HStack {
                        Text("PROGRAM")
                            .font(.caption.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(ProShowTheme.liveRed)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.45))
                        Spacer()
                    }
                    .padding(16)
                    Spacer()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: slide?.id)
    }
}

/// Compact next / preview monitor for the operator desk.
struct PreviewMonitorView: View {
    let slide: Slide?
    let label: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(accent)

            AudienceView(slide: slide, showsChrome: false)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(accent.opacity(0.45), lineWidth: 1)
                )
                .aspectRatio(16 / 9, contentMode: .fit)
        }
    }
}

#Preview("Audience") {
    AudienceView(
        slide: Slide(lines: ["Amazing grace, how sweet the sound", "That saved a wretch like me"]),
        showsChrome: true
    )
}
