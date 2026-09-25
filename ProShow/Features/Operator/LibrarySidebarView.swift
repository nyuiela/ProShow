import SwiftUI

/// Left column: Library + Playlist + show items (top) and Media sources (bottom).
struct LibrarySidebarView: View {
    @Bindable var controller: ShowController
    @State private var selectedItemTitle: String = DeskSampleData.playlistItems.first(where: \.isActive)?.title
        ?? "Amazing Grace (Sample)"

    var body: some View {
        VStack(spacing: 0) {
            libraryBlock
            PaneHairline()
            mediaBlock
        }
        .background(ProShowTheme.panel)
    }

    private var libraryBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader(title: "Library", showsAdd: true)
            SearchFieldChrome(placeholder: "Search")
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(DeskSampleData.libraryFolders) { folder in
                        SidebarRow(title: folder.name, systemImage: folder.systemImage)
                    }

                    SidebarSectionHeader(title: "Playlist", showsAdd: true)
                        .padding(.top, 8)

                    ForEach(DeskSampleData.playlists) { folder in
                        SidebarRow(title: folder.name, systemImage: folder.systemImage)
                    }

                    Text("ITEMS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)

                    // Live show from controller + sample playlist rows
                    SidebarSelectableRow(
                        title: controller.show.name,
                        isSelected: selectedItemTitle == controller.show.name
                    ) {
                        selectedItemTitle = controller.show.name
                    }

                    ForEach(DeskSampleData.playlistItems) { item in
                        SidebarSelectableRow(
                            title: item.title,
                            isSelected: selectedItemTitle == item.title
                        ) {
                            selectedItemTitle = item.title
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var mediaBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader(title: "Media", showsAdd: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(DeskSampleData.mediaSources) { source in
                        DisclosureGroup {
                            ForEach(source.children) { child in
                                SidebarRow(title: child.name, systemImage: child.systemImage, indented: true)
                            }
                        } label: {
                            SidebarRow(title: source.name, systemImage: source.systemImage)
                        }
                        .tint(ProShowTheme.secondaryLabel)
                        .padding(.horizontal, 4)
                    }
                }
            }
            .frame(minHeight: 140, idealHeight: 180, maxHeight: 220)
        }
    }
}

struct SidebarSectionHeader: View {
    let title: String
    var showsAdd: Bool

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Spacer()
            if showsAdd {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ProShowTheme.toolbarIcon)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(ProShowTheme.well.opacity(0.55))
    }
}

struct SidebarRow: View {
    let title: String
    let systemImage: String
    var indented: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(ProShowTheme.accent.opacity(0.9))
                .frame(width: 14)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, indented ? 22 : 10)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
    }
}

struct SidebarSelectableRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? ProShowTheme.accent : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}

struct SearchFieldChrome: View {
    var placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Text(placeholder)
                .font(.caption)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(ProShowTheme.well)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct PaneHairline: View {
    var body: some View {
        Rectangle()
            .fill(ProShowTheme.hairline)
            .frame(height: DeskPaneDivider.width)
    }
}
