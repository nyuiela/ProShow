import SwiftUI
#if os(macOS)
import AppKit
#endif

/// CueLog kinetic / scroll teleprompter for one rundown script body.
struct RundownTeleprompterView: View {
    let script: String
    @Bindable var settings: TeleprompterSettingsStore
    @Bindable var session: TeleprompterSession
    @Bindable private var floatChrome = PromptFloatController.shared
    var surface: PromptSurface = .embedded
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var copiedWebsiteURL: String?
    @State private var lastAutoCopiedWordID: UUID?
    @State private var lastLinkCopyAt: Date?
    @State private var scrollLayoutWidth: CGFloat = 0

    private var engine: KineticEngine { session.engine }
    private var scroll: ScrollEngine { session.scroll }

    var body: some View {
        Group {
            if surface == .compact {
                compactBar
            } else {
                fullStage
            }
        }
        .onAppear { reloadScript() }
        .onChange(of: script) { _, _ in reloadScript() }
        .onChange(of: settings.baseWPM) { _, _ in reloadScript() }
        .onChange(of: settings.style.lineBreakPause) { _, _ in reloadScript() }
        .onChange(of: settings.style.tagPause) { _, _ in reloadScript() }
        .onChange(of: settings.style.longTagPause) { _, _ in reloadScript() }
        .onChange(of: settings.style.punctuationHolds) { _, _ in reloadScript() }
        .onChange(of: settings.style.motionEnabled) { _, _ in reloadScript() }
        .onChange(of: settings.style.chunkCapacity) { _, capacity in
            engine.setChunkCapacity(capacity)
        }
        .onChange(of: engine.activeIndex) { _, index in
            guard settings.promptEngine == .kinetic else { return }
            autoCopyArrivedLink(wordIndex: index)
        }
        .onChange(of: engine.isRunning) { _, running in
            guard running, settings.promptEngine == .kinetic else { return }
            autoCopyArrivedLink(wordIndex: engine.activeIndex)
        }
        .onChange(of: scroll.offset) { _, _ in
            guard settings.promptEngine == .scroll else { return }
            autoCopyArrivedLink(wordIndex: scrollLinkWordIndex())
        }
        .onChange(of: scroll.isRunning) { _, running in
            guard running, settings.promptEngine == .scroll else { return }
            autoCopyArrivedLink(wordIndex: scrollLinkWordIndex())
        }
    }

    private var fullStage: some View {
        VStack(spacing: 0) {
            transport
            ZStack {
                stageBackdrop
                if settings.promptEngine == .kinetic {
                    kineticStage
                } else {
                    scrollStage
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: surface == .extended ? 22 : 8, style: .continuous))
            .padding(.horizontal, surface == .extended ? 10 : 16)
            .padding(.bottom, surface == .extended ? 10 : 12)
        }
        .padding(.horizontal, surface == .extended ? 6 : (surface == .compact ? 0 : 8))
        .padding(.bottom, surface == .extended ? 6 : (surface == .compact ? 0 : 8))
        .padding(.top, surface == .extended ? 2 : (surface == .compact ? 0 : 8))
        .background {
            if surface == .embedded {
                Color.clear
            }
        }
        .overlay {
            if surface == .extended {
                promptResizeRim
            }
        }
        .promptGlass(cornerRadius: 28, solid: reduceTransparency, enabled: surface != .compact)
    }

    /// Edges resize the extended window. The top bar still moves it.
    private var promptResizeRim: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0).allowsHitTesting(false)
                PromptResizeHandle(edge: .bottom)
                    .frame(height: 10)
            }
            HStack(spacing: 0) {
                PromptResizeHandle(edge: .left)
                    .frame(width: 8)
                Spacer(minLength: 0).allowsHitTesting(false)
                PromptResizeHandle(edge: .right)
                    .frame(width: 8)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0).allowsHitTesting(false)
                HStack(spacing: 0) {
                    PromptResizeHandle(edge: .bottomLeft)
                        .frame(width: 18, height: 18)
                    Spacer(minLength: 0).allowsHitTesting(false)
                    PromptResizeHandle(edge: .bottomRight)
                        .frame(width: 18, height: 18)
                        .overlay {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.55))
                                .allowsHitTesting(false)
                        }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var stageBackdrop: some View {
        Group {
            if surface == .embedded {
                Color.clear
            } else if surface == .extended, !reduceTransparency {
                Rectangle().fill(.clear)
            } else {
                Color.black.opacity(surface == .extended ? 0.28 : 1)
            }
        }
    }

    private var compactBar: some View {
        ZStack {
            PromptWindowDragHandle { floatChrome.snapAfterDrag() }
                .accessibilityLabel("Drag prompt")
                .accessibilityHint("Drag up to the menu bar, or down to the Dock")
            HStack(alignment: .center, spacing: 4) {
                VStack(spacing: 4) {
                    promptIconButton(
                        settings.compactLiquidGlass ? "drop.fill" : "circle.dotted",
                        label: settings.compactLiquidGlass ? "Liquid glass" : "Transparent",
                        hint: settings.compactLiquidGlass ? "Switch the prompt to transparent" : "Switch the prompt to liquid glass"
                    ) {
                        settings.compactLiquidGlass.toggle()
                    }
                    Spacer(minLength: 0)
                    outlineStepButton("chevron.up", label: "Previous outline", delta: -1)
                    outlineStepButton("chevron.down", label: "Next outline", delta: 1)
                }
                Group {
                    if settings.promptEngine == .kinetic {
                        kineticStage
                    } else {
                        scrollStage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                compactControls
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .promptGlass(cornerRadius: 22, solid: reduceTransparency, enabled: settings.compactLiquidGlass)
        .onChange(of: settings.fontSize) { _, _ in floatChrome.relayoutCompact() }
        .onChange(of: settings.style.shoutScale) { _, _ in floatChrome.relayoutCompact() }
    }

    /// Reading size for the island. The extended stage keeps the user’s type size.
    private var readingFontSize: CGFloat {
        guard surface == .compact else { return CGFloat(settings.fontSize) }
        return min(17, max(13, CGFloat(settings.fontSize) * 0.36))
    }

    private var compactControls: some View {
        VStack(spacing: 4) {
            promptIconButton(
                session.transport.systemImage,
                label: session.transport.title,
                hint: session.transport == .pause ? "Holds the playhead on this word" : "Starts from the current word"
            ) {
                session.primaryAction(settings: settings)
            }
            promptIconButton("arrow.counterclockwise", label: "Restart teleprompter") {
                session.restart(settings: settings)
            }
            promptIconButton("arrow.up.left.and.arrow.down.right", label: "Expand prompt") {
                floatChrome.expand()
            }
        }
    }

    private func promptIconButton(
        _ symbol: String,
        label: String,
        hint: String? = nil,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(PromptGlassButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .promptHint(hint)
    }

    private var outlineIndex: Int {
        floatChrome.rundown?.rundownFocusedBlockIndex ?? 0
    }

    private var outlineCount: Int {
        guard let show = floatChrome.rundown else { return 0 }
        return (show.rundownClock.program ?? show.programDocument).rundownBlocks.count
    }

    private var focusedOutlineBlock: RundownBlock? {
        guard let show = floatChrome.rundown else { return nil }
        let blocks = (show.rundownClock.program ?? show.programDocument).rundownBlocks
        guard blocks.indices.contains(show.rundownFocusedBlockIndex) else { return nil }
        return blocks[show.rundownFocusedBlockIndex]
    }

    private func websiteURL(in word: SpokenWord) -> String? {
        guard !word.isPauseOnly else { return nil }
        return PromptWebsiteURL.match(word.text, cues: focusedOutlineBlock?.linkCues ?? [])
    }

    private func autoCopyArrivedLink(wordIndex: Int?) {
        guard let wordIndex, engine.words.indices.contains(wordIndex) else {
            lastAutoCopiedWordID = nil
            return
        }
        let word = engine.words[wordIndex]
        guard let url = websiteURL(in: word) else {
            lastAutoCopiedWordID = nil
            return
        }
        guard lastAutoCopiedWordID != word.id else { return }
        lastAutoCopiedWordID = word.id
        copyLink(url)
    }

    /// Eye-line word while scrolling: the website on the line the playhead has reached.
    private func scrollLinkWordIndex() -> Int? {
        let width = scrollLayoutWidth
        guard width > 8 else { return nil }
        let fontSize = readingFontSize
        let lineBox = fontSize * 1.35
        let gap: CGFloat = 2
        let lines = KineticLineBreaker.lines(words: engine.words, maxWidth: width, fontSize: fontSize)
        var y: CGFloat = 0
        let eye = CGFloat(scroll.offset)
        for line in lines {
            let extra: CGFloat = line.beginsAfterHardBreak ? lineBox * 0.45 : 0
            let top = y + extra
            let bottom = top + lineBox
            if eye >= top, eye < bottom + gap {
                return line.wordIndices.first { index in
                    engine.words.indices.contains(index) && websiteURL(in: engine.words[index]) != nil
                }
            }
            y = bottom + gap
        }
        return nil
    }

    private func copyLink(_ url: String) {
        #if os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(url, forType: .string)
        #endif
        lastLinkCopyAt = Date()
        copiedWebsiteURL = url
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedWebsiteURL == url { copiedWebsiteURL = nil }
        }
    }

    private func outlineStepButton(_ symbol: String, label: String, delta: Int) -> some View {
        let enabled = delta < 0 ? outlineIndex > 0 : outlineIndex < outlineCount - 1
        return promptIconButton(symbol, label: label, enabled: enabled) {
            floatChrome.rundown?.stepRundownOutline(by: delta)
        }
    }

    private func outlineTransportButton(_ symbol: String, label: String, delta: Int) -> some View {
        let enabled = delta < 0 ? outlineIndex > 0 : outlineIndex < outlineCount - 1
        return Button {
            floatChrome.rundown?.stepRundownOutline(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(PromptGlassButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(label)
        .accessibilityLabel(label)
    }

    private var transport: some View {
        HStack(spacing: 8) {
            glassTransport(showsExtend: true)
            Text(settings.promptEngine == .kinetic ? "\(settings.baseWPM) WPM" : String(format: "%.0f pt/s", settings.scrollSpeed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(RundownChrome.mutedLabel)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
                .allowsHitTesting(false)
            if session.isRunning {
                Text("On script")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ProShowTheme.accent)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, surface == .extended ? 4 : 8)
        .frame(maxWidth: .infinity, minHeight: surface == .extended ? 36 : 44)
        .background {
            if surface == .extended {
                PromptWindowDragHandle { floatChrome.snapAfterDrag() }
                    .accessibilityLabel("Drag prompt")
                    .accessibilityHint("Drag up to the menu bar, or down to the Dock")
            }
        }
    }

    private func glassTransport(showsExtend: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                session.primaryAction(settings: settings)
            } label: {
                Image(systemName: session.transport.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(PromptGlassButtonStyle())
            .accessibilityLabel(session.transport.title)
            .accessibilityHint(session.transport == .pause ? "Holds the playhead on this word" : "Starts from the current word")

            Button {
                session.restart(settings: settings)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(PromptGlassButtonStyle())
            .accessibilityLabel("Restart teleprompter")

            if surface == .extended {
                outlineTransportButton("chevron.up", label: "Previous outline", delta: -1)
                outlineTransportButton("chevron.down", label: "Next outline", delta: 1)
            }

            if showsExtend {
                Button {
                    floatChrome.toggle()
                } label: {
                    Image(systemName: floatChrome.isOpen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(PromptGlassButtonStyle())
                .accessibilityLabel(floatChrome.isOpen ? "Return prompt" : "Extend prompt")
            }
        }
    }

    /// Tap toggles play. A vertical drag scrubs words, the same way CueLog does.
    private var scrubOrTapGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard hypot(value.translation.width, value.translation.height) >= 4 else { return }
                session.handleScrubChanged(translationY: value.translation.height, settings: settings)
            }
            .onEnded { value in
                if let lastLinkCopyAt, Date().timeIntervalSince(lastLinkCopyAt) < 0.35 { return }
                let distance = hypot(value.translation.width, value.translation.height)
                if session.handleStageTap(distance: distance, settings: settings) { return }
                session.handleScrubEnded(
                    translationY: value.translation.height,
                    predictedTranslationY: value.predictedEndTranslation.height,
                    settings: settings
                )
            }
    }

    private var kineticStage: some View {
        GeometryReader { geo in
            let margin: CGFloat = surface == .compact ? 12 : 28
            let textWidth = max(8, geo.size.width - margin * 2)
            let fontSize = readingFontSize
            let lineBox = surface == .compact
                ? fontSize * 1.62 + 4
                : fontSize * max(1.45, settings.style.shoutScale + 0.15) + 18
            let anchorY = geo.size.height * (surface == .compact ? 0.46 : settings.eyeLinePosition)
            ZStack {
                kineticLines(textWidth: textWidth, lineBox: lineBox, fontSize: fontSize)
                    .frame(width: geo.size.width)
                    .position(
                        x: geo.size.width / 2,
                        y: stackCenterY(anchorY: anchorY, lineBox: lineBox)
                    )
                    .scaleEffect(x: settings.mirrorHorizontal ? -1 : 1, y: 1)

                EyeLineMarker(quiet: surface == .compact)
                    .padding(.horizontal, margin)
                    .position(x: geo.size.width / 2, y: anchorY)
                    .allowsHitTesting(false)

                if surface == .compact {
                    compactPauseCue
                } else if settings.style.showsLongPauseBanner {
                    TimelineView(.periodic(from: TimelineAnchor.start, by: 0.1)) { _ in
                        if let pause = engine.activeLongPause {
                            LongPauseBanner(remaining: pause.remaining, total: pause.total)
                                .padding(.top, 12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                engine.updateLayout(
                    width: textWidth,
                    height: geo.size.height,
                    fontSize: fontSize,
                    fontName: ".AppleSystemUIFont",
                    lineBoxHeight: lineBox
                )
            }
            .onChange(of: geo.size) { _, size in
                engine.updateLayout(
                    width: max(8, size.width - margin * 2),
                    height: size.height,
                    fontSize: fontSize,
                    fontName: ".AppleSystemUIFont",
                    lineBoxHeight: lineBox
                )
            }
            .contentShape(Rectangle())
            .gesture(scrubOrTapGesture)
            .accessibilityHint("Tap to play or pause. Drag up or down to move through the words.")
        }
    }

    private func kineticLines(textWidth: CGFloat, lineBox: CGFloat, fontSize: CGFloat) -> some View {
        let gap = KineticLineMetrics.wordGap(fontSize: fontSize)
        return VStack(spacing: 0) {
            ForEach(Array(engine.visibleLines)) { line in
                HStack(spacing: gap) {
                    ForEach(line.wordIndices, id: \.self) { index in
                        if engine.words.indices.contains(index) {
                            PromptWordView(
                                word: engine.words[index],
                                role: role(for: index),
                                style: settings.style,
                                fontSize: fontSize,
                                motionEnabled: settings.style.motionEnabled && !reduceMotion,
                                showsLongPauseInline: surface != .compact && settings.style.showsLongPauseInline,
                                emphasizesActiveWord: surface == .compact,
                                linkURL: websiteURL(in: engine.words[index]),
                                linkCopied: copiedWebsiteURL == websiteURL(in: engine.words[index]),
                                onCopyLink: { copyLink($0) },
                                onLinkPress: { lastLinkCopyAt = Date() }
                            )
                        }
                    }
                }
                .frame(width: textWidth, height: lineBox, alignment: .center)
            }
        }
    }

    private func stackCenterY(anchorY: CGFloat, lineBox: CGFloat) -> CGFloat {
        let visible = Array(engine.visibleLines)
        guard !visible.isEmpty else { return anchorY }
        let stackHeight = CGFloat(visible.count) * lineBox
        let activeLine = engine.activeLineIndex ?? engine.lineWindow.startLine
        let slot = max(0, activeLine - engine.lineWindow.startLine)
        return anchorY + stackHeight / 2 - CGFloat(slot) * lineBox - lineBox / 2
    }

    private var scrollStage: some View {
        GeometryReader { geo in
            let textWidth = max(8, geo.size.width - 56)
            ScrollView {
                scrollScript(width: textWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, geo.size.height * settings.eyeLinePosition)
                    .background {
                        GeometryReader { textGeo in
                            Color.clear.preference(key: PromptContentHeightKey.self, value: textGeo.size.height)
                        }
                    }
            }
            .scrollDisabled(true)
            .offset(y: -scroll.offset)
            .scaleEffect(x: settings.mirrorHorizontal ? -1 : 1, y: 1)
            .onPreferenceChange(PromptContentHeightKey.self) { height in
                scroll.contentHeight = height
                scroll.viewportHeight = geo.size.height
                scroll.speedPointsPerSecond = settings.scrollSpeed
            }
            .overlay(alignment: .center) {
                EyeLineMarker(quiet: surface == .compact)
                    .padding(.horizontal, surface == .compact ? 36 : 28)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if surface == .compact {
                    compactPauseCue
                }
            }
            .onAppear { scrollLayoutWidth = textWidth }
            .onChange(of: textWidth) { _, width in scrollLayoutWidth = width }
            .contentShape(Rectangle())
            .highPriorityGesture(scrubOrTapGesture)
            .accessibilityHint("Tap to play or pause. Drag up or down to move through the script.")
        }
        .onChange(of: settings.scrollSpeed) { _, speed in
            scroll.speedPointsPerSecond = speed
        }
    }

    private func scrollScript(width: CGFloat) -> some View {
        let fontSize = readingFontSize
        let lines = KineticLineBreaker.lines(words: engine.words, maxWidth: width, fontSize: fontSize)
        let gap = max(4, fontSize * 0.22)
        let lineBox = fontSize * 1.35
        return VStack(spacing: 2) {
            if lines.isEmpty {
                Text("No script for this item.")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.white)
            }
            ForEach(lines) { line in
                HStack(spacing: gap) {
                    ForEach(line.wordIndices, id: \.self) { index in
                        if engine.words.indices.contains(index) {
                            scrollToken(engine.words[index])
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: lineBox)
                .padding(.top, line.beginsAfterHardBreak ? lineBox * 0.45 : 0)
            }
        }
    }

    private func scrollToken(_ word: SpokenWord) -> some View {
        let active = engine.words.firstIndex(where: { $0.id == word.id }) == engine.activeIndex
        let size = Double(readingFontSize) * (surface == .compact && active ? 1.22 : 1)
        let label = word.isLongPause
            ? (surface == .compact ? "" : "〔\(word.longPauseLabel)〕")
            : word.text
        let opacity: Double = {
            if word.isLongPause { return 0.55 }
            switch word.vocalStyle {
            case .whisper: return 0.7
            case .fast: return 0.85
            default: return 1
            }
        }()
        let url = word.isPauseOnly ? nil : websiteURL(in: word)
        let token = Text(label)
            .font(scrollFont(for: word.vocalStyle, size: size))
            .underline(url != nil, color: Color.white.opacity(0.45))
            .foregroundStyle(Color.white.opacity(opacity))
        return PromptLinkCopyAnchor(
            url: url,
            copied: url != nil && copiedWebsiteURL == url,
            onCopy: { copyLink($0) },
            onPress: { lastLinkCopyAt = Date() }
        ) {
            if word.vocalStyle.prefersItalic {
                token.italic()
            } else {
                token
            }
        }
    }

    private var compactPauseCue: some View {
        TimelineView(.periodic(from: TimelineAnchor.start, by: 0.1)) { _ in
            if let pause = engine.activeLongPause {
                CompactPauseCue(remaining: pause.remaining, total: pause.total)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    private func scrollFont(for style: VocalStyle, size: Double) -> Font {
        let weight: Font.Weight = {
            if style.prefersHeavyWeight { return .heavy }
            if style.prefersLightWeight { return .light }
            if style == .bounce || style == .melody { return .semibold }
            return .regular
        }()
        if style.prefersMonospaced {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        if style.prefersRounded {
            return .system(size: size, weight: weight, design: .rounded)
        }
        return .system(size: size, weight: weight)
    }

    private func role(for index: Int) -> PromptWordRole {
        if index < engine.activeIndex { return .passed }
        if index == engine.activeIndex { return .active }
        return .upcoming
    }

    private func reloadScript() {
        session.loadIfNeeded(script: script, settings: settings)
    }
}

private struct PromptContentHeightKey: PreferenceKey {
    static var defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = max(value, nextValue())
    }
}

enum PromptWordRole {
    case passed, active, upcoming
}

struct PromptWordView: View {
    let word: SpokenWord
    let role: PromptWordRole
    let style: KineticStyle
    let fontSize: CGFloat
    var motionEnabled: Bool
    var showsLongPauseInline: Bool = true
    /// Compact island: the spoken word sits a step above the rest of the line.
    var emphasizesActiveWord: Bool = false
    var linkURL: String? = nil
    var linkCopied: Bool = false
    var onCopyLink: ((String) -> Void)? = nil
    var onLinkPress: (() -> Void)? = nil

    var body: some View {
        if word.isBriefPause {
            EmptyView()
        } else if word.isLongPause {
            if showsLongPauseInline {
                Text(word.longPauseLabel)
                    .font(.system(size: max(12, fontSize * 0.36), weight: .semibold))
                    .foregroundStyle(style.activeColor.color.opacity(role == .active ? 1 : 0.45))
                    .accessibilityLabel(word.longPauseLabel)
            }
        } else {
            PromptLinkCopyAnchor(
                url: linkURL,
                copied: linkCopied,
                onCopy: { onCopyLink?($0) },
                onPress: { onLinkPress?() }
            ) {
                spokenText
                    .underline(linkURL != nil, color: Color.white.opacity(0.45))
                    .foregroundStyle(color)
                    .scaleEffect(scale)
                    .lineLimit(1)
                    .minimumScaleFactor(word.isJoinedPhrase ? 0.38 : 0.72)
                    .animation(motionEnabled ? .easeOut(duration: 0.16) : nil, value: role == .active)
            }
        }
    }

    private var promptFont: Font {
        let size = fontSize * sizeScale
        if word.vocalStyle.prefersMonospaced {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        if word.vocalStyle.prefersRounded {
            return .system(size: size, weight: weight, design: .rounded)
        }
        return .system(size: size, weight: weight)
    }

    private var spokenText: Text {
        let text = Text(word.text).font(promptFont)
        if word.vocalStyle.prefersItalic {
            return text.italic()
        }
        return text
    }

    private var weight: Font.Weight {
        if word.vocalStyle.prefersHeavyWeight { return .heavy }
        if word.vocalStyle.prefersLightWeight { return .light }
        if word.vocalStyle == .bounce || word.vocalStyle == .melody { return .semibold }
        return .regular
    }

    private var sizeScale: CGFloat {
        let styled: CGFloat = switch word.vocalStyle {
        case .shout: CGFloat(style.shoutScale)
        case .whisper: CGFloat(style.whisperScale)
        default: 1
        }
        guard role == .active else { return styled }
        if emphasizesActiveWord { return styled * 1.22 }
        if style.activePunchEnabled && motionEnabled { return styled * CGFloat(style.activePunchScale) }
        return styled
    }

    private var scale: CGFloat { 1 }

    private var color: Color {
        switch role {
        case .active:
            style.activeColor.color.opacity(word.vocalStyle == .whisper ? style.whisperOpacity : 1)
        case .passed:
            style.passedColor.color.opacity(style.passedOpacity * (word.vocalStyle == .whisper ? style.whisperOpacity : 1))
        case .upcoming:
            style.upcomingColor.color.opacity(style.upcomingOpacity * (word.vocalStyle == .whisper ? style.whisperOpacity : 1))
        }
    }
}

private struct EyeLineMarker: View {
    var quiet: Bool = false

    var body: some View {
        Rectangle()
            .fill(Color(red: 1, green: 0.84, blue: 0).opacity(quiet ? 0.28 : 0.85))
            .frame(width: quiet ? 56 : nil, height: quiet ? 1 : 2)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// Copy control that appears on a website token. Hover reveals it; arrival copies on its own.
private struct PromptLinkCopyAnchor<Content: View>: View {
    let url: String?
    let copied: Bool
    var onCopy: (String) -> Void
    var onPress: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            content()
            if let url, hovering || copied {
                Button {
                    onCopy(url)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PromptGlassButtonStyle())
                .accessibilityLabel(copied ? "Link copied" : "Copy link")
                .help("Copy \(url)")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0).onChanged { _ in onPress() }
                )
            }
        }
        .onHover { hovering = $0 }
        .accessibilityAction(named: Text("Copy link")) {
            if let url { onCopy(url) }
        }
    }
}

private struct CompactPauseCue: View {
    let remaining: TimeInterval
    let total: TimeInterval

    private var progress: Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, 1 - remaining / total))
    }

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Color.white.opacity(0.16))
                .frame(height: 2)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color(red: 1, green: 0.86, blue: 0.4).opacity(0.85))
                            .frame(width: max(2, geo.size.width * progress))
                    }
                }
            Text("\(max(0, Int(remaining.rounded())))s")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(width: 22, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.28), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Long pause, \(max(0, Int(remaining.rounded()))) seconds remaining")
    }
}

private struct LongPauseBanner: View {
    let remaining: TimeInterval
    let total: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Long pause · \(max(0, Int(remaining.rounded())))s")
                .font(.system(size: 13, weight: .semibold))
            ProgressView(value: total > 0 ? 1 - remaining / total : 1)
                .tint(Color(red: 1, green: 0.92, blue: 0.2))
        }
        .padding(10)
        .frame(maxWidth: 280)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Long pause, \(max(0, Int(remaining.rounded()))) seconds remaining")
    }
}

/// Settings → Teleprompter. Same knobs CueLog uses for breaks and word display.
struct TeleprompterSettingsPane: View {
    @Bindable var settings: TeleprompterSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            SettingsGroup(title: "Engine") {
                SettingsRow(title: "Prompt", detail: "Scroll moves the page. Kinetic spills one word at a time.") {
                    Picker("Prompt", selection: $settings.promptEngine) {
                        ForEach(PromptEngineKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                SettingsRow(title: "Speaking rate", detail: "Kinetic hold and the library read-time estimate.") {
                    labeledSlider(value: Binding(
                        get: { Double(settings.baseWPM) },
                        set: { settings.baseWPM = Int($0.rounded()) }
                    ), range: 60...240, label: "\(settings.baseWPM) WPM")
                }
                SettingsRow(title: "Type size") {
                    labeledSlider(value: $settings.fontSize, range: 24...96, label: "\(Int(settings.fontSize)) pt")
                }
                SettingsRow(title: "Scroll speed", detail: "Points per second in scroll mode.") {
                    labeledSlider(value: $settings.scrollSpeed, range: 8...160, label: String(format: "%.0f", settings.scrollSpeed))
                }
                SettingsRow(title: "Mirror", detail: "Flip horizontally for a beam-splitter glass.") {
                    Toggle("Mirror", isOn: $settings.mirrorHorizontal)
                        .labelsHidden()
                }
            }

            SettingsGroup(title: "Breaks") {
                SettingsRow(title: "Line break", detail: "Hold after a return. Not a [PAUSE] tag.") {
                    labeledSlider(value: $settings.style.lineBreakPause, range: 0...0.8, label: String(format: "%.2fs", settings.style.lineBreakPause))
                }
                SettingsRow(title: "[PAUSE]", detail: "Bare pause tag, about a beat.") {
                    labeledSlider(value: $settings.style.tagPause, range: 0.05...2, label: String(format: "%.2fs", settings.style.tagPause))
                }
                SettingsRow(title: "[LONGPAUSE]", detail: "Used when the tag has no :Ns duration.") {
                    labeledSlider(value: $settings.style.longTagPause, range: 2...30, label: String(format: "%.0fs", settings.style.longTagPause))
                }
                SettingsRow(title: "Inline chip") {
                    Toggle("Show long pause in the line", isOn: $settings.style.showsLongPauseInline)
                        .labelsHidden()
                }
                SettingsRow(title: "Countdown") {
                    Toggle("Show long pause banner", isOn: $settings.style.showsLongPauseBanner)
                        .labelsHidden()
                }
            }

            SettingsGroup(title: "Words on screen") {
                SettingsRow(title: "Lines", detail: "How many kinetic lines stay up.") {
                    labeledSlider(value: Binding(
                        get: { Double(max(1, settings.style.chunkCapacity / 5)) },
                        set: { settings.style.chunkCapacity = Int($0.rounded()) * 5 }
                    ), range: 1...12, label: "\(max(1, settings.style.chunkCapacity / 5))")
                }
                SettingsRow(title: "Ahead", detail: "Opacity of words not yet spoken.") {
                    labeledSlider(value: $settings.style.upcomingOpacity, range: 0.05...1, label: String(format: "%.0f%%", settings.style.upcomingOpacity * 100))
                }
                SettingsRow(title: "Shout size") {
                    labeledSlider(value: $settings.style.shoutScale, range: 1...1.6, label: String(format: "%.2f×", settings.style.shoutScale))
                }
                SettingsRow(title: "Whisper size") {
                    labeledSlider(value: $settings.style.whisperScale, range: 0.7...1, label: String(format: "%.2f×", settings.style.whisperScale))
                }
                SettingsRow(title: "Motion", detail: "Scale the active word. Off keeps color only.") {
                    Toggle("Motion", isOn: $settings.style.motionEnabled)
                        .labelsHidden()
                }
                HStack(spacing: 8) {
                    ForEach(KineticStyle.presets, id: \.title) { preset in
                        Button(preset.title) { settings.applyPreset(preset.style) }
                            .buttonStyle(DeskPressButtonStyle())
                    }
                }
            }

            SettingsGroup(title: "Punctuation holds") {
                holdRow("Comma", value: $settings.style.punctuationHolds.comma)
                holdRow("Period", value: $settings.style.punctuationHolds.period)
                holdRow("Question", value: $settings.style.punctuationHolds.question)
                holdRow("Exclamation", value: $settings.style.punctuationHolds.exclamation)
                holdRow("Ellipsis", value: $settings.style.punctuationHolds.ellipsis)
            }
        }
    }

    private func holdRow(_ title: String, value: Binding<TimeInterval>) -> some View {
        SettingsRow(title: title) {
            labeledSlider(value: value, range: 0...3, label: String(format: "%.2fs", value.wrappedValue))
        }
    }

    private func labeledSlider(value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: range)
                .frame(width: 160)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

struct PromptGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .background {
                Capsule(style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.22 : 0.12))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6)
                    }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PromptGlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    var solid: Bool
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if solid {
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.88))
            }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    }
            }
        }
    }
}

extension View {
    func promptGlass(cornerRadius: CGFloat, solid: Bool, enabled: Bool = true) -> some View {
        modifier(PromptGlassModifier(cornerRadius: cornerRadius, solid: solid, enabled: enabled))
    }

    @ViewBuilder
    fileprivate func promptHint(_ hint: String?) -> some View {
        if let hint, !hint.isEmpty {
            self.accessibilityHint(hint)
        } else {
            self
        }
    }
}
