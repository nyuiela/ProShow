import SwiftUI

/// Full-color platform marks (SVG in Assets) for settings and connect flows.
struct StreamPlatformBrandIcon: View {
    var platform: StreamPlatform
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let asset = Self.assetName(for: platform) {
                if platform == .twitter {
                    ZStack {
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(Color(hex: platform.tintHex) ?? .black)
                        Image(asset)
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.22)
                    }
                } else {
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill((Color(hex: platform.tintHex) ?? ProShowTheme.accent).opacity(0.18))
                    Image(systemName: platform.systemImage)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Color(hex: platform.tintHex) ?? ProShowTheme.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func assetName(for platform: StreamPlatform) -> String? {
        switch platform {
        case .youtube: "StreamBrandYouTube"
        case .facebook: "StreamBrandFacebook"
        case .twitter: "StreamBrandX"
        case .linkedin: "StreamBrandLinkedIn"
        case .customRtmp, .srt: nil
        }
    }
}
