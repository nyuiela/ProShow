import SwiftUI

struct NodeBackdropView: View {
    let group: MapBackdropGroup
    var onMove: (Double, Double) -> Void
    var onToggleCollapse: () -> Void

    @State private var liveDrag: CGSize = .zero

    var body: some View {
        let height = group.isCollapsed ? 36 : group.height
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 8) {
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                    Text(group.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(group.childIDs.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help(group.isCollapsed ? "Expand backdrop" : "Collapse backdrop")
            .accessibilityLabel(group.title)
            .accessibilityHint(group.isCollapsed ? "Double-click header to expand" : "Double-click header to collapse")
            .onTapGesture(count: 2, perform: onToggleCollapse)
            .gesture(moveGesture)
            if !group.isCollapsed {
                Spacer(minLength: 0)
            }
        }
        .frame(width: max(group.width, 160), height: max(height, 36), alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill((Color(hex: group.colorHex) ?? Color.purple).opacity(group.isCollapsed ? 0.55 : 0.22))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder((Color(hex: group.colorHex) ?? Color.purple).opacity(0.7), lineWidth: 1.2)
        }
        .offset(x: group.x + liveDrag.width, y: group.y + liveDrag.height)
        .allowsHitTesting(true)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                liveDrag = value.translation
            }
            .onEnded { value in
                onMove(group.x + value.translation.width, group.y + value.translation.height)
                liveDrag = .zero
            }
    }
}
