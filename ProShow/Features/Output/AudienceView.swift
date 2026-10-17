import SwiftUI
#if canImport(CoreVideo)
import CoreVideo
#endif

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

            if let slide, !slide.canvas.isEmpty {
                ProgramSlideCanvas(
                    objects: slide.canvas,
                    canvasWidth: CanvasConfig.width,
                    canvasHeight: CanvasConfig.height
                )
            } else if let slide, !slide.isBlank, !slide.displayText.isEmpty {
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
                        Text("Program")
                            .font(DeskType.meta)
                            .foregroundStyle(ProShowTheme.liveRed)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.45), in: Capsule(style: .continuous))
                            .accessibilityLabel("Program output")
                        Spacer()
                    }
                    .padding(DeskSpace.md)
                    Spacer()
                }
            }
        }
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22), value: slide?.id)
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
                .font(DeskType.meta)
                .foregroundStyle(accent)

            AudienceView(slide: slide, showsChrome: false)
                .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                        .strokeBorder(accent.opacity(0.45), lineWidth: 1)
                )
                .aspectRatio(DeskLayout.programAspect, contentMode: .fit)
        }
    }
}

/// Stream monitor: shows the encoded program (`program.encode`) — same composite as YouTube / X RTMP.
struct StreamProgramView: View {
    @Bindable var controller: ShowController
    var showsChrome: Bool = true

    var body: some View {
        GeometryReader { proxy in
            let canvasW = CGFloat(max(controller.streaming.config.width, 16))
            let canvasH = CGFloat(max(controller.streaming.config.height, 16))
            let scale = min(proxy.size.width / canvasW, proxy.size.height / canvasH)
            let fitted = CGSize(width: canvasW * scale, height: canvasH * scale)
            ZStack {
                ProShowTheme.stageBlack
                ZStack(alignment: .topLeading) {
                    feed
                    if showsChrome {
                        chrome
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ProShowTheme.stageBlack)
        .lockFlickerFreeBackground()
        .overlay(alignment: .bottomLeading) {
            DeskSignalProbeView(controller: controller, style: .outputOverlay)
                .padding(16)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(statusLabel)
        .accessibilityValue(statusValue)
    }

    @ViewBuilder
    private var feed: some View {
        ZStack {
            ProShowTheme.stageBlack
            ProgramCanonicalMonitorView(
                controller: controller,
                outputEnabled: controller.programOutputEnabled,
                isRenderingPaused: !controller.programOutputEnabled
            )
        }
        .onAppear {
            controller.evaluateProgramClockState()
        }
        .onDisappear {
            controller.evaluateProgramClockState()
        }
    }

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                statusPill
                Spacer()
                if controller.streaming.isLive {
                    TimelineView(.periodic(from: TimelineAnchor.start, by: 1)) { context in
                        Text(StreamingEngine.broadcastTimecode(from: controller.streaming.startedAt, now: context.date))
                            .font(DeskType.mono)
                            .foregroundStyle(ProShowTheme.primaryLabel)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.5), in: Capsule(style: .continuous))
                    }
                }
            }
            .padding(12)
            Spacer()
            HStack {
                Text(destinationLine)
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.primaryLabel)
                    .lineLimit(1)
                Spacer()
                Text("\(controller.streaming.config.width)×\(controller.streaming.config.height)")
                    .font(DeskType.mono)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45))
        }
        .allowsHitTesting(false)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusTitle)
                .font(DeskType.bodyEmph)
                .foregroundStyle(ProShowTheme.primaryLabel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.55), in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }

    private var statusTitle: String {
        if controller.streaming.isLive { return ProShowCopy.Status.live }
        if controller.streaming.state == .starting { return ProShowCopy.Status.connecting }
        return ProShowCopy.Status.ready
    }

    private var statusColor: Color {
        if controller.streaming.isLive { return ProShowTheme.liveRed }
        if controller.streaming.state == .starting { return ProShowTheme.accent }
        return ProShowTheme.statusOff
    }

    private var destinationLine: String {
        let names = controller.streaming.config.relayDestinations.map(\.name).filter { !$0.isEmpty }
        if names.count >= 2 {
            return names.joined(separator: " · ")
        }
        if controller.streaming.isLive {
            return controller.streaming.config.useCloudRelay ? "Cloud relay" : "Direct RTMP"
        }
        return "Encoded program"
    }

    private var statusLabel: String { "Stream output" }

    private var statusValue: String {
        if controller.streaming.isLive {
            return ProShowCopy.meta([ProShowCopy.Status.live, destinationLine])
        }
        if controller.streaming.state == .starting {
            return ProShowCopy.Status.connecting
        }
        return ProShowCopy.Status.ready
    }
}

#Preview("Audience") {
    AudienceView(
        slide: Slide(lines: ["Starting soon", "Program begins shortly"]),
        showsChrome: true
    )
}
