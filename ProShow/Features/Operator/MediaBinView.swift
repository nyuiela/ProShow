import SwiftUI

/// Lower center media browser — breadcrumb path + thumbnail strip.
struct MediaBinView: View {
    @State private var filter = ""
    @State private var zoom: Double = 0.45

    private var items: [MediaBinItem] {
        let all = DeskSampleData.mediaBin
        guard !filter.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PaneHairline()
            thumbStrip
            PaneHairline()
            footer
        }
        .background(ProShowTheme.panel)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Playlists")
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Text("Stellar")
                .foregroundStyle(.primary)
            Spacer()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var thumbStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    MediaThumbCard(item: item, scale: zoom)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(minHeight: 100, idealHeight: 118)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
            Image(systemName: "play.fill")
            Image(systemName: "backward.fill")
            Image(systemName: "forward.fill")

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                    .frame(width: 120)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ProShowTheme.well)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Spacer()

            Image(systemName: "square.grid.2x2")
                .foregroundStyle(ProShowTheme.accent)
            Slider(value: $zoom, in: 0.25...1)
                .tint(ProShowTheme.accent)
                .frame(maxWidth: 90)
        }
        .font(.caption)
        .foregroundStyle(ProShowTheme.toolbarIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct MediaThumbCard: View {
    let item: MediaBinItem
    let scale: Double

    private var width: CGFloat { 96 + CGFloat(scale) * 70 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(hex: item.tintHex) ?? ProShowTheme.well)
                    .overlay {
                        switch item.kind {
                        case .camera:
                            Image(systemName: "camera.fill")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.85))
                        case .video:
                            Image(systemName: "film")
                                .foregroundStyle(.white.opacity(0.35))
                        case .image:
                            Image(systemName: "photo")
                                .foregroundStyle(.white.opacity(0.35))
                        case .placeholder:
                            EmptyView()
                        }
                    }

                if case let .video(duration) = item.kind {
                    Text(duration)
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.65))
                        .foregroundStyle(.white)
                        .padding(3)
                }

                if case let .camera(label) = item.kind {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .foregroundStyle(ProShowTheme.statusOn)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
            )

            Text(item.title)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .foregroundStyle(ProShowTheme.secondaryLabel)
        }
    }
}
