import SwiftUI

struct NodeCommandPaletteView: View {
    var items: [NodeCommandItem]
    var onChoose: (NodeCommandItem) -> Void
    var onCancel: () -> Void

    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var fieldFocused: Bool

    private var filtered: [NodeCommandItem] {
        NodeCommandCatalog.filter(items, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .accessibilityHidden(true)
                TextField("Add node or source…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { confirm() }
                    .accessibilityLabel("Add node or source")
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle()
                .fill(ProShowTheme.hairline)
                .frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            Button {
                                onChoose(item)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbolName)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(item.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(ProShowTheme.secondaryLabel)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(ProShowTheme.primaryLabel)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(index == highlight ? ProShowTheme.well : Color.clear)
                                )
                            }
                            .buttonStyle(DeskPressButtonStyle())
                            .id(item.id)
                            .accessibilityAddTraits(index == highlight ? .isSelected : [])
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 280)
                .onChange(of: highlight) { _, value in
                    if filtered.indices.contains(value) {
                        proxy.scrollTo(filtered[value].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 360)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(ProShowTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
        }
        .onAppear {
            fieldFocused = true
            highlight = 0
        }
        .onChange(of: query) { _, _ in
            highlight = 0
        }
        .onExitCommand(perform: onCancel)
        .onMoveCommand { direction in
            switch direction {
            case .up:
                highlight = max(0, highlight - 1)
            case .down:
                highlight = min(max(filtered.count - 1, 0), highlight + 1)
            default:
                break
            }
        }
    }

    private func confirm() {
        guard filtered.indices.contains(highlight) else { return }
        onChoose(filtered[highlight])
    }
}
