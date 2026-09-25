import SwiftUI

/// Center column: show title + slide thumbnail grid + transport / zoom chrome.
struct SlideWorkspaceView: View {
    @Bindable var controller: ShowController
    @State private var zoom: Double = 0.55
    @State private var transitionSeconds: Double = 0.6

    private var columns: [GridItem] {
        let size = 140 + zoom * 120
        return [GridItem(.adaptive(minimum: size, maximum: size + 40), spacing: 12)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PaneHairline()
            slideGrid
            PaneHairline()
            bottomChrome
        }
        .background(ProShowTheme.canvas)
    }

    private var header: some View {
        HStack {
            Text(controller.show.name)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(controller.show.allSlides.count) slides")
                .font(.caption)
                .foregroundStyle(ProShowTheme.secondaryLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ProShowTheme.panel)
    }

    private var slideGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(controller.show.allSlides.enumerated()), id: \.element.id) { index, slide in
                    SlideThumbnailCard(
                        index: index + 1,
                        slide: slide,
                        isSelected: slide.id == controller.selectedSlideID,
                        isLive: !controller.isAudienceCleared && slide.id == controller.liveSlideID
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { controller.goLive(slideID: slide.id) }
                    .onTapGesture(count: 1) { controller.select(slide.id) }
                }
            }
            .padding(14)
        }
    }

    private var bottomChrome: some View {
        HStack(spacing: 10) {
            Button { controller.goPrevious() } label: {
                Image(systemName: "backward.end.fill")
            }
            Button { controller.goLive() } label: {
                Image(systemName: "play.fill")
            }
            Button { controller.advance() } label: {
                Image(systemName: "forward.end.fill")
            }

            Text(String(format: "%.1fs", transitionSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .frame(width: 36, alignment: .trailing)

            Slider(value: $transitionSeconds, in: 0...2, step: 0.1)
                .tint(ProShowTheme.accent)
                .frame(maxWidth: 140)

            Spacer()

            Image(systemName: "square.grid.2x2")
                .foregroundStyle(ProShowTheme.accent)
            Image(systemName: "list.bullet")
                .foregroundStyle(ProShowTheme.secondaryLabel)

            Slider(value: $zoom, in: 0...1)
                .tint(ProShowTheme.accent)
                .frame(maxWidth: 100)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ProShowTheme.toolbarIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ProShowTheme.panel)
    }
}

struct SlideThumbnailCard: View {
    let index: Int
    let slide: Slide
    let isSelected: Bool
    let isLive: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ProShowTheme.stageBlack)

                if !slide.isBlank {
                    Text(slide.displayText.isEmpty ? slide.title : slide.displayText)
                        .font(.system(size: 11, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ProShowTheme.lyricWhite)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .minimumScaleFactor(0.5)
                }

                Text("\(index)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(5)

                if isLive {
                    Text("LIVE")
                        .font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(ProShowTheme.liveRed)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(4)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        isLive ? ProShowTheme.liveRed : (isSelected ? ProShowTheme.accent : ProShowTheme.hairline),
                        lineWidth: isLive || isSelected ? 2 : 1
                    )
            )
        }
    }
}
