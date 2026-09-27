import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore
#endif

/// SwiftUI wrapper around the shared IOSurface Metal host.
struct SharedTextureHostView: View {
    var style: MediaFrameStyle = .plain

    var body: some View {
        SharedTextureHostRepresentable(style: style)
    }
}

#if os(macOS)
private struct SharedTextureHostRepresentable: NSViewRepresentable {
    var style: MediaFrameStyle

    func makeNSView(context: Context) -> ProShowMetalHostView {
        let view = ProShowMetalHostView()
        DeskLiveLayer.applyFrameStyle(view, style: style)
        view.lastStyle = style
        view.attachPublisher()
        return view
    }

    func updateNSView(_ nsView: ProShowMetalHostView, context: Context) {
        if nsView.lastStyle != style {
            DeskLiveLayer.applyFrameStyle(nsView, style: style)
            nsView.lastStyle = style
        }
        DeskLiveLayer.syncMetalDrawable(in: nsView, size: nsView.bounds.size)
    }

    static func dismantleNSView(_ nsView: ProShowMetalHostView, coordinator: ()) {
        SharedTexturePublisher.shared.removeConsumer(ObjectIdentifier(nsView))
    }
}

/// Display-link probe that invalidates only the local SwiftUI subtree that owns it.
struct DisplayLinkBridge: NSViewRepresentable {
    var onTick: () -> Void

    func makeNSView(context: Context) -> DisplayLinkBridgeNSView {
        let view = DisplayLinkBridgeNSView()
        view.onTick = onTick
        return view
    }

    func updateNSView(_ nsView: DisplayLinkBridgeNSView, context: Context) {
        nsView.onTick = onTick
    }

    static func dismantleNSView(_ nsView: DisplayLinkBridgeNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class DisplayLinkBridgeNSView: NSView {
    var onTick: (() -> Void)?
    private var link: CADisplayLink?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        onTick?()
    }
}
#else
private struct SharedTextureHostRepresentable: View {
    var style: MediaFrameStyle
    var body: some View { Color.black }
}

struct DisplayLinkBridge: View {
    var onTick: () -> Void
    var body: some View { Color.clear.accessibilityHidden(true) }
}
#endif
