import SwiftUI

/// Talent cards and active rundown block metadata for the Rundown workspace.
struct ProgramInspectorView: View {
    @Bindable var controller: ShowController
    @Binding var selectedTalentID: UUID?

    private var program: ProgramDocumentModel {
        controller.rundownClock.program ?? controller.programDocument
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DeskSpace.md) {
                DeskSectionTitle(title: "Program")
                Text(program.showTitle)
                    .font(DeskType.meta.weight(.semibold))
                    .foregroundStyle(ProShowTheme.primaryLabel)
                if let block = controller.rundownClock.activeBlock {
                    activeBlockSection(block)
                }
                talentSection
            }
            .padding(12)
        }
        .background(ProShowTheme.panel)
    }

    private func activeBlockSection(_ block: RundownBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active segment")
                .font(DeskType.micro.weight(.semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(block.itemNumber) · \(block.title)")
                    .font(DeskType.meta.weight(.semibold))
                HStack {
                    Text("Remaining")
                        .font(DeskType.micro)
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                    Text(ProgramTimecode.format(max(0, controller.rundownClock.activeBlockRemainingSeconds)))
                        .font(DeskType.mono.weight(.semibold))
                        .foregroundStyle(ProShowTheme.accent)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProShowTheme.well, in: RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        }
    }

    private var talentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Talent")
                .font(DeskType.micro.weight(.semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            ForEach(program.talentDatabase) { talent in
                talentCard(talent)
            }
        }
    }

    private func talentCard(_ talent: TalentProfile) -> some View {
        let selected = selectedTalentID == talent.id
        return VStack(alignment: .leading, spacing: 6) {
            Text(talent.fullName)
                .font(DeskType.meta.weight(.semibold))
                .foregroundStyle(ProShowTheme.lyricWhite)
            Text(TalentManager.displayLine(for: talent))
                .font(DeskType.micro)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            if let mic = talent.microphoneChannelName, !mic.isEmpty {
                Label(mic, systemImage: "mic.fill")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            if let notes = talent.speakerNotes, !notes.isEmpty {
                Text(notes)
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .lineLimit(3)
            }
            Button("Fire lower third") {
                TalentManager.fireLowerThird(talent: talent, controller: controller)
            }
            .font(DeskType.micro)
            .buttonStyle(DeskPressButtonStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? ProShowTheme.accent.opacity(0.12) : ProShowTheme.well, in: RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                .strokeBorder(selected ? ProShowTheme.accent.opacity(0.5) : ProShowTheme.hairline, lineWidth: 1)
        }
        .onTapGesture { selectedTalentID = talent.id }
    }
}
