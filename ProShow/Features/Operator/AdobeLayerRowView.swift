import SwiftUI
#if os(macOS)
import AppKit
#endif

struct AdobeLayerRowView: View {
    let item: CanvasLayerItem
    let isSelected: Bool
    var showsDragHandle: Bool = true
    let onSelect: () -> Void
    let onToggleVisibility: () -> Void
    let onToggleLock: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditingName = false
    @State private var editedName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleVisibility) {
                Image(systemName: item.isVisible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.isVisible ? ProShowTheme.primaryLabel : ProShowTheme.secondaryLabel.opacity(0.45))
                    .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel(item.isVisible ? "Hide \(item.name)" : "Show \(item.name)")

            Button(action: onToggleLock) {
                Image(systemName: item.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.isLocked ? ProShowTheme.accent : ProShowTheme.secondaryLabel.opacity(0.45))
                    .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel(item.isLocked ? "Unlock \(item.name)" : "Lock \(item.name)")

            Group {
                thumbnail

                VStack(alignment: .leading, spacing: 1) {
                    if isEditingName {
                        TextField("Layer name", text: $editedName, onCommit: commitRename)
                            .textFieldStyle(.plain)
                            .font(DeskType.meta.weight(.semibold))
                            .foregroundStyle(ProShowTheme.lyricWhite)
                            .focused($nameFocused)
                            .onAppear { nameFocused = true }
                    } else {
                        Text(item.name)
                            .font(DeskType.meta.weight(.semibold))
                            .foregroundStyle(item.isVisible ? ProShowTheme.lyricWhite : ProShowTheme.secondaryLabel)
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                editedName = item.name
                                isEditingName = true
                            }
                    }
                    Text(item.kindDetail)
                        .font(DeskType.micro)
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                        .lineLimit(1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
            .onTapGesture(perform: onSelect)

            Spacer(minLength: 4)

            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ProShowTheme.secondaryLabel.opacity(0.35))
                    .accessibilityHidden(true)
            }

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ProShowTheme.toolbarIcon)
                    .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel("Delete \(item.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? ProShowTheme.accent.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                    .strokeBorder(ProShowTheme.accent.opacity(0.7), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.kindDetail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.black)
            #if os(macOS)
            if let thumb = item.thumbnailImage {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Image(systemName: item.kind.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            #else
            Image(systemName: item.kind.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            #endif
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func commitRename() {
        let next = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !next.isEmpty, next != item.name {
            onRename(next)
        }
        isEditingName = false
        nameFocused = false
    }
}
