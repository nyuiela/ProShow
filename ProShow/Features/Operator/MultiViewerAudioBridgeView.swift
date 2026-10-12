import SwiftUI

/// Hardware-style dBFS bridge for the MultiViewer meters tile.
struct MultiViewerAudioBridgeView: View {
    var controller: ShowController

    var body: some View {
        VStack(spacing: 0) {
            header
            scale
            Divider().overlay(ProShowTheme.hairline)
            AudioMeterBridgeView(orientation: .horizontal) {
                controller.multiViewerMeterChannels.map { channel in
                    AudioMeterSample(
                        id: channel.id,
                        name: channel.name,
                        db: channel.db,
                        holdDb: channel.holdDb,
                        isMuted: channel.isMuted
                    )
                }
            }
        }
        .background(ProShowTheme.stageInk)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Master audio meters")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProShowTheme.statusOn)
                .accessibilityHidden(true)
            Text("Meters")
                .font(DeskType.meta.weight(.semibold))
                .foregroundStyle(ProShowTheme.primaryLabel)
            Spacer()
            Text("16 ch  dBFS")
                .font(DeskType.mono)
                .foregroundStyle(ProShowTheme.secondaryLabel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(ProShowTheme.titlebar)
    }

    private var scale: some View {
        HStack(spacing: 0) {
            Text("Ch")
                .frame(width: 64, alignment: .leading)
            HStack(spacing: 0) {
                Text("−60").frame(maxWidth: .infinity, alignment: .leading)
                Text("−18").frame(maxWidth: .infinity)
                Text("−3").frame(maxWidth: .infinity)
                Text("+3").frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text("Pk")
                .frame(width: 36, alignment: .trailing)
        }
        .font(DeskType.mono)
        .foregroundStyle(ProShowTheme.secondaryLabel)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(ProShowTheme.panel)
        .accessibilityHidden(true)
    }
}