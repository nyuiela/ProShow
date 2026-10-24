import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif

/// 9:16 Phone canvas confidence. Preview and Live use the same chrome as the Stream monitor.
struct PhoneCanvasMonitorChrome: View {
    @Bindable var controller: ShowController
    var size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            ProShowTheme.stageBlack
            PhoneCanvasPicture(
                controller: controller,
                feed: controller.inspector.phonePreviewFeed,
                playsCueAudio: true,
                showsCueLabel: false
            )
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .overlay(alignment: .topTrailing) {
            PhonePreviewExpandButton()
                .padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            PhoneDualChannelMeter(
                controller: controller,
                barHeight: max(36, size.height - InspectorPreviewLayout.meterInset * 2)
            )
            .padding(InspectorPreviewLayout.meterInset)
        }
        .overlay(alignment: .bottomTrailing) {
            if controller.inspector.phonePreviewFeed == .audience {
                PreviewHeadsetButton()
                    .padding(InspectorPreviewLayout.meterInset)
            }
        }
        .background(ProShowTheme.stageBlack, in: RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Phone monitor, \(controller.inspector.phonePreviewFeed.title)")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: controller.inspector.phonePreviewFeed)
    }
}

/// Phone picture for the right pane and MultiViewer tiles.
struct PhoneCanvasPicture: View {
    @Bindable var controller: ShowController
    var feed: PreviewFeed
    var playsCueAudio: Bool = false
    var showsCueLabel: Bool = true

    var body: some View {
        ZStack {
            ProShowTheme.stageBlack
            switch feed {
            case .audience:
                previewSurface
                    .environment(\.dynamicText, controller.canonicalProgramDynamicText())
            case .stream, .stage, .matrix:
                liveSurface
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if feed == .audience, showsCueLabel {
                Text(cueLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ProShowTheme.lyricWhite)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(ProShowTheme.titlebar.opacity(0.92), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .onAppear {
            guard playsCueAudio, feed == .audience else { return }
            controller.followOperatorPreviewAudio(true)
        }
        .onDisappear {
            guard playsCueAudio else { return }
            controller.followOperatorPreviewAudio(false)
        }
        .onChange(of: controller.operatorPreviewSlide?.id) { _, _ in
            guard playsCueAudio, feed == .audience else { return }
            controller.followOperatorPreviewAudio(true)
        }
    }

    private var accessibilityName: String {
        feed == .audience ? "Phone preview, \(cueLabel)" : "Phone live"
    }

    private var cueLabel: String {
        guard let slide = controller.operatorPreviewSlide else { return "No next cue" }
        let name = slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? slide.previewSummary : name
        if controller.phoneCanvasBoard(on: slide) != nil {
            return "Phone · \(title)"
        }
        if let selected = controller.selectedSlide, selected.id == slide.id, selected.id != controller.liveSlideID {
            return "From Stream · \(title)"
        }
        return "From Stream · Next"
    }

    @ViewBuilder
    private var previewSurface: some View {
        if let slide = controller.operatorPreviewSlide {
            phoneBoardOrFitted(slide: slide, isLive: false)
        } else {
            Text("No next cue")
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
        }
    }

    @ViewBuilder
    private var liveSurface: some View {
        #if canImport(CoreVideo)
        PhoneLivePixelSurface(controller: controller)
        #else
        if let slide = controller.liveSlide {
            phoneBoardOrFitted(slide: slide, isLive: true)
        } else {
            Text("Phone")
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
        }
        #endif
    }

    @ViewBuilder
    private func phoneBoardOrFitted(slide: Slide, isLive: Bool) -> some View {
        if let board = controller.phoneCanvasBoard(on: slide) {
            ProgramSlideThumbnailPreview(
                controller: controller,
                slide: slide,
                objects: controller.resolvedCanvasObjects(board.objects),
                canvasWidth: board.width,
                canvasHeight: board.height
            )
        } else {
            PhoneFromStreamLetterbox(controller: controller, slide: slide, isLive: isLive)
        }
    }
}

#if canImport(CoreVideo)
private struct PhoneLivePixelSurface: View {
    @Bindable var controller: ShowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 4.0 : 1.0 / 20.0, paused: reduceMotion || !onScreen)) { _ in
            // The expanded Phone window is its own scene and does not inherit the operator window's
            // live text, so timers drew 0:00 there. Resolve it here on every tick.
            content
                .environment(\.dynamicText, controller.canonicalProgramDynamicText())
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    @ViewBuilder
    private var content: some View {
        if let buffer = PhoneComposedFrame.shared.fresh(),
           let image = InputPreviewImaging.image(from: buffer) {
            #if os(macOS)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        } else if let slide = controller.liveSlide {
            if let board = controller.phoneCanvasBoard(on: slide) {
                ProgramSlideThumbnailPreview(
                    controller: controller,
                    slide: slide,
                    objects: controller.resolvedCanvasObjects(board.objects) + controller.livePhonePropObjects(width: board.width, height: board.height),
                    canvasWidth: board.width,
                    canvasHeight: board.height
                )
            } else {
                PhoneFromStreamLetterbox(controller: controller, slide: slide, isLive: true)
            }
        } else {
            Text("Phone")
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
        }
    }
}
#endif

private struct PhoneFromStreamLetterbox: View {
    @Bindable var controller: ShowController
    var slide: Slide?
    var isLive: Bool

    var body: some View {
        ZStack {
            Color.black
            Group {
                if isLive {
                    RightPaneProgramView(controller: controller)
                } else if let slide {
                    let objects = controller.resolvedCanvasObjects(slide.audienceCanvas())
                    let width = slide.editorCanvases.first(where: \.isPrimary)?.width ?? CanvasConfig.width
                    let height = slide.editorCanvases.first(where: \.isPrimary)?.height ?? CanvasConfig.height
                    ProgramSlideThumbnailPreview(
                        controller: controller,
                        slide: slide,
                        objects: objects,
                        canvasWidth: width,
                        canvasHeight: height
                    )
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                Spacer()
                Text("From Stream")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ProShowTheme.lyricWhite)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(ProShowTheme.titlebar.opacity(0.92), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(8)
            }
            .allowsHitTesting(false)
        }
        .accessibilityLabel(isLive ? "Phone live, From Stream" : "Phone preview, From Stream")
    }
}

/// Same program master meter as the stream monitor overlay and the Audio tab Program strip.
fileprivate struct PhoneDualChannelMeter: View {
    var controller: ShowController
    var barHeight: CGFloat

    var body: some View {
        AudioMeterBridgeView(orientation: .vertical) {
            DualChannelMeter.programSamples(matrix: controller.audioMatrix)
        }
        .frame(width: InspectorPreviewLayout.meterWidth, height: barHeight)
        .accessibilityLabel("Program levels")
    }
}

#if os(macOS)
fileprivate struct PhonePreviewFeedButton: View {
    @Bindable var controller: ShowController

    var body: some View {
        Menu {
            ForEach(PreviewFeed.operatorFeeds) { feed in
                Button {
                    controller.selectPhonePreviewFeed(feed)
                } label: {
                    if controller.inspector.phonePreviewFeed == feed {
                        Label(feed.title, systemImage: "checkmark")
                    } else {
                        Text(feed.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(controller.inspector.phonePreviewFeed.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(ShowSidebarPalette.title)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12).opacity(0.9), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .help("Switch Phone between Preview and Live")
        .accessibilityLabel("Phone monitor")
        .accessibilityValue(controller.inspector.phonePreviewFeed.title)
    }
}

fileprivate struct PhonePreviewExpandButton: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .proShowOpenPhoneWindow, object: nil)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.title)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12).opacity(0.9), lineWidth: 1)
                }
        }
        .buttonStyle(DeskPressButtonStyle())
        .help("Open Phone in an expanded window")
        .accessibilityLabel("Expand Phone preview")
    }
}
#endif
