import SwiftUI

/// Role-based composition stack — hides compositor slot indices from operators.
struct UserCompositionPanelView: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme

    private var elements: [UserVisibleElement] {
        controller.userVisibleElements
    }

    var body: some View {
        let _ = controller.compositor.slideRevision
        let _ = controller.compositor.mediaRevision
        let _ = controller.playback.isPlaying
        VStack(alignment: .leading, spacing: DeskSpace.sm) {
            header
            elementStack
                .frame(minHeight: 72, maxHeight: DeskLayout.compositionLayersListMaxHeight, alignment: .top)
                .layoutPriority(1)
            quickClearStrip
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composition stack")
        .onDeleteCommand(perform: removeSelectedElements)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Active on-air")
                    .font(DeskType.meta.weight(.semibold))
                    .foregroundStyle(ShowSidebarPalette.title)
                Text("\(controller.activeElementCount) active")
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
            }
            Spacer()
            Button {
                controller.compositionAddTextLayer()
            } label: {
                Image(systemName: "plus")
                    .font(DeskControlSize.regular.iconFont)
                    .foregroundStyle(ShowSidebarPalette.symbol)
                    .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help("Add text to slide")
            .accessibilityLabel("Add text to slide")
        }
    }

    @ViewBuilder
    private var elementStack: some View {
        if elements.isEmpty {
            Text("Nothing on program.")
                .font(DeskType.micro)
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(elements.enumerated()), id: \.element.id) { index, item in
                        UserLayerRowView(
                            controller: controller,
                            item: item,
                            isSelected: controller.compositionPanelSelection.contains(item.id),
                            onSelect: { selectElement(item.id) },
                            onToggleVisibility: { controller.toggleVisibility(for: item.id) },
                            onToggleLock: { controller.toggleLock(for: item.id) },
                            onDismiss: {
                                controller.requestDeskDestructiveConfirm(
                                    .removeOnAirElement(displayName: item.displayName, id: item.id)
                                )
                            }
                        )
                        if index < elements.count - 1 {
                            InspectorRowRule()
                        }
                    }
                }
            }
        }
    }

    private var quickClearStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick clear")
                .font(DeskType.micro)
                .foregroundStyle(ShowSidebarPalette.subtitle)
            HStack(spacing: 4) {
                quickClearButton("text.quote", label: "Clear lyrics") {
                    controller.requestDeskDestructiveConfirm(.clearLyrics)
                }
                quickClearButton("rectangle.bottomthird.inset.filled", label: "Clear lower thirds") {
                    controller.requestDeskDestructiveConfirm(.clearLowerThirds)
                }
                Spacer(minLength: 0)
                quickClearButton("xmark.circle.fill", label: "Clear all on-air", tint: ProShowTheme.liveRed) {
                    controller.requestDeskDestructiveConfirm(.clearAllOnAir)
                }
            }
        }
    }

    private func selectElement(_ id: UUID) {
        #if os(macOS)
        let additive = NSEvent.modifierFlags.contains(.command)
        #else
        let additive = false
        #endif
        controller.compositionSelectLayer(id: id, additive: additive)
    }

    private func removeSelectedElements() {
        let count = controller.compositionPanelSelection.count
        guard count > 0 else { return }
        controller.requestDeskDestructiveConfirm(
            .removeSelectedCompositionElements(count: count)
        )
    }

    private func quickClearButton(
        _ systemImage: String,
        label: String,
        tint: Color = ShowSidebarPalette.symbol,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

struct UserLayerRowView: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("proshow.layers.swipeDeleteDirection") private var swipeDeleteDirection = "left"
    let item: UserVisibleElement
    var isSelected: Bool = false
    let onSelect: () -> Void
    let onToggleVisibility: () -> Void
    let onToggleLock: () -> Void
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    private var canMuteAudio: Bool {
        guard let layer = controller.renderLayerForProgramElement(item.id) else { return false }
        return controller.canMuteProgramLayer(layer)
    }

    private var isAudioMuted: Bool {
        guard let layer = controller.renderLayerForProgramElement(item.id) else { return false }
        return controller.isProgramLayerAudioMuted(layer)
    }

    /// Negative when a left swipe removes the layer.
    private var deleteSign: CGFloat {
        swipeDeleteDirection == "right" ? 1 : -1
    }

    var body: some View {
        row
            .offset(x: dragOffset)
            .background {
                swipeReveal
            }
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(swipeGesture)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("Remove \(item.displayName)")) {
                onDismiss()
            }
    }

    private var row: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isSelected ? ProShowTheme.accent : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 5)
                .accessibilityHidden(true)

            Image(systemName: item.role.iconName)
                .font(DeskControlSize.compact.iconFont)
                .foregroundStyle(roleAccent)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            Button(action: onSelect) {
                Text(item.displayName)
                    .font(DeskType.meta.weight(.semibold))
                    .foregroundStyle(item.isVisible ? ShowSidebarPalette.title : ShowSidebarPalette.subtitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel(item.displayName)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            controlCluster
        }
        .padding(.leading, 4)
        .padding(.trailing, isSelected ? 34 : 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if isSelected {
                Button(action: onDismiss) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(ProShowTheme.liveRed, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .padding(.trailing, 4)
                .help("Remove \(item.displayName)")
                .accessibilityLabel("Remove \(item.displayName)")
            }
        }
    }

    private var controlCluster: some View {
        HStack(spacing: 0) {
            layerTool(
                systemImage: item.isVisible ? "eye.fill" : "eye.slash",
                label: item.isVisible ? "Hide \(item.displayName)" : "Show \(item.displayName)",
                tint: item.isVisible ? ShowSidebarPalette.symbol : ProShowTheme.accent,
                action: onToggleVisibility
            )
            layerTool(
                systemImage: item.isLocked ? "lock.fill" : "lock.open",
                label: item.isLocked ? "Unlock \(item.displayName)" : "Lock \(item.displayName)",
                tint: item.isLocked ? ProShowTheme.accent : ShowSidebarPalette.symbol,
                action: onToggleLock
            )
            layerTool(
                systemImage: isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2",
                label: isAudioMuted ? "Unmute \(item.displayName)" : "Mute \(item.displayName)",
                tint: isAudioMuted ? ProShowTheme.liveRed : ShowSidebarPalette.symbol,
                enabled: canMuteAudio,
                action: { controller.toggleProgramElementAudio(id: item.id) }
            )
        }
        .padding(1)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        }
        .accessibilityElement(children: .contain)
    }

    private var swipeReveal: some View {
        let revealWidth = max(0, dragOffset * deleteSign)
        return Color.clear
            .overlay(alignment: deleteSign > 0 ? .leading : .trailing) {
                ZStack {
                    ProShowTheme.liveRed
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                .frame(width: revealWidth)
                .clipped()
            }
            .accessibilityHidden(true)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                let translation = value.translation
                guard abs(translation.width) > abs(translation.height) else { return }
                dragOffset = resisted(translation.width)
            }
            .onEnded { value in
                let translation = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let along = translation * deleteSign
                let flick = predicted * deleteSign
                if along > 56 || flick > 110 {
                    onDismiss()
                }
                if reduceMotion {
                    dragOffset = 0
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func resisted(_ translation: CGFloat) -> CGFloat {
        let towardDelete = translation * deleteSign > 0
        return towardDelete ? translation : translation * 0.2
    }

    private func layerTool(
        systemImage: String,
        label: String,
        tint: Color,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(label)
        .accessibilityLabel(label)
    }

    private var roleAccent: Color {
        switch item.role {
        case .background, .camera, .mainContent, .lowerThird, .graphicOverlay:
            ProShowTheme.accent
        case .emergencyAlert:
            ProShowTheme.liveRed
        }
    }
}

#if os(macOS)
import AppKit
#endif
