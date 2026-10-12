import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Launch home: sidebar + featured actions + recents, mapped from the project’s real create/open flow.
struct StartMenuView: View {
    var preferences: AppLaunchPreferences
    var isLaunching: Bool = false
    var launchError: String?
    var onCreate: (String, URL) -> Void
    var onOpen: (URL) -> Void
    var onSelectTheme: (String) -> Void = { _ in }

    @State private var newName = "Untitled Program"
    @State private var isImporterPresented = false
    @State private var pane: StartHomePane = .home
    @State private var recentFilter: StartRecentFilter = .all
    @FocusState private var nameFieldFocused: Bool

    private var lastProject: RecentProject? { preferences.recent.first }

    private var visibleRecents: [RecentProject] {
        switch recentFilter {
        case .all:
            return preferences.recent
        case .week:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            return preferences.recent.filter { $0.lastOpenedAt >= cutoff }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if pane == .home {
                            featuredRow
                            themesSection
                        }
                        recentsSection
                        if pane == .home {
                            starterTiles
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 1100, alignment: .leading)
                }
                .focusEffectDisabled()
                dock
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StartHome.page)
        }
        .frame(minWidth: 1080, minHeight: 680)
        .background(StartHome.page.ignoresSafeArea())
        .lockFlickerFreeBackground()
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let launchError, !launchError.isEmpty {
                Text(launchError)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StartHome.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 560)
                    .background(StartHome.blush, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 16)
                    .accessibilityLabel("Could not open project")
                    .accessibilityValue(launchError)
            }
        }
        .overlay {
            if isLaunching {
                ZStack {
                    Color.black.opacity(0.45)
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                        Text("Opening project…")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(StartHome.dock, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .ignoresSafeArea()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Opening project")
            }
        }
        .disabled(isLaunching)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                onOpen(url)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProShowMark()
                Text("ProShow")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 4) {
                navButton("Home", systemImage: "square.grid.2x2", selected: pane == .home) {
                    pane = .home
                }
                navButton("Recents", systemImage: "clock", selected: pane == .recents) {
                    pane = .recents
                }
                navButton("New project", systemImage: "plus.square") {
                    nameFieldFocused = true
                    createProject()
                }
                navButton("Open…", systemImage: "folder") {
                    openExisting()
                }
            }

            Spacer(minLength: 16)

            #if os(macOS)
            navButton("Quit", systemImage: "rectangle.portrait.and.arrow.right") {
                NSApp.terminate(nil)
            }
            .padding(.bottom, 20)
            #endif
        }
        .frame(width: 200, alignment: .leading)
        .background(StartHome.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start menu")
    }

    private func navButton(_ title: String, systemImage: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(selected ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .padding(.horizontal, 8)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var featuredRow: some View {
        HStack(spacing: 16) {
            StartHeroCard(
                title: "New show",
                subtitle: newName,
                actionTitle: "Create project",
                actionImage: "play.fill",
                fill: StartHome.lemon,
                ink: StartHome.ink,
                art: .beam
            ) {
                createProject()
            }
            StartHeroCard(
                title: lastProject == nil ? "Open a show" : "Continue",
                subtitle: lastProject?.name ?? "Any .proshow bundle",
                actionTitle: lastProject == nil ? "Open…" : "Resume",
                actionImage: lastProject == nil ? "folder.fill" : "pause.fill",
                fill: StartHome.tangerine,
                ink: StartHome.ink,
                art: .lens
            ) {
                if let lastProject {
                    onOpen(lastProject.url)
                } else {
                    openExisting()
                }
            }
        }
    }

    private var themesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Theme")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(preferences.selectedTheme)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(DeskSampleData.themes, id: \.self) { theme in
                    themeCard(theme)
                }
            }
        }
    }

    private func themeCard(_ name: String) -> some View {
        let selected = preferences.selectedTheme == name
        return Button {
            onSelectTheme(name)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: themeSymbol(name))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StartHome.ink.opacity(0.82))
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StartHome.ink)
                    }
                }
                Text(name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(StartHome.ink)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 88)
            .background(themeTint(name), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Color.white : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Applies this look when a project opens")
    }

    private func themeTint(_ name: String) -> Color {
        switch name {
        case "Lyric Standard": StartHome.lemon
        case "Lower Third": StartHome.aqua
        case "Sermon Point", "Talk Point": StartHome.blush
        case "Lyrics": StartHome.butter
        case "Scripture": StartHome.coral
        default: StartHome.tangerine
        }
    }

    private func themeSymbol(_ name: String) -> String {
        switch name {
        case "Lyric Standard", "Lyrics": "text.aligncenter"
        case "Lower Third": "rectangle.bottomhalf.inset.filled"
        case "Sermon Point", "Talk Point": "text.quote"
        case "Scripture": "book.closed"
        default: "rectangle.on.rectangle"
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(pane == .recents ? "Recent projects" : "Pick up where you left off")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if pane == .home, !preferences.recent.isEmpty {
                    Button("View all") { pane = .recents }
                        .buttonStyle(DeskPressButtonStyle())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .accessibilityHint("Shows every recent project")
                }
            }

            if !preferences.recent.isEmpty {
                HStack(spacing: 8) {
                    chip("All", selected: recentFilter == .all) { recentFilter = .all }
                    chip("This week", selected: recentFilter == .week) { recentFilter = .week }
                    Spacer(minLength: 0)
                }
            }

            if visibleRecents.isEmpty {
                Text(preferences.recent.isEmpty
                     ? "Create a project or open a .proshow bundle. It will show up here next time."
                     : "Nothing opened this week.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleRecents.prefix(pane == .home ? 4 : 12).enumerated()), id: \.element.id) { index, project in
                        recentRow(project, tint: StartHome.rowTint(index))
                    }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? StartHome.ink : Color.white.opacity(0.8))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(selected ? Color.white : Color.white.opacity(0.08), in: Capsule(style: .continuous))
                .contentShape(Capsule())
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func recentRow(_ project: RecentProject, tint: Color) -> some View {
        Button {
            onOpen(project.url)
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StartHome.ink.opacity(0.85))
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(project.url.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Show")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: 72, alignment: .leading)
                Text(RelativeDateTimeFormatter().localizedString(for: project.lastOpenedAt, relativeTo: Date()))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: 88, alignment: .trailing)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel("Open \(project.name)")
        .accessibilityHint(project.path)
    }

    private var starterTiles: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Start from a setup")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                StartTileCard(title: "New program", detail: "Hold, talk, lyrics, end card", fill: StartHome.blush, art: .host) {
                    newName = "Untitled Program"
                    createProject()
                }
                StartTileCard(title: "Open bundle", detail: "Existing .proshow", fill: StartHome.aqua, art: .wave) {
                    openExisting()
                }
                StartTileCard(title: "Untitled", detail: "Same starter, new name", fill: StartHome.coral, art: .burst) {
                    newName = "Untitled Program"
                    createProject()
                }
                StartTileCard(title: "Talk set", detail: "Talk plus lyrics", fill: StartHome.butter, art: .pages) {
                    newName = "Talk Set"
                    createProject()
                }
            }
        }
    }

    private var dock: some View {
        HStack(spacing: 16) {
            Button {
                if let lastProject {
                    onOpen(lastProject.url)
                } else {
                    openExisting()
                }
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StartHome.tangerine)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "film.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(StartHome.ink)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lastProject?.name ?? "No recent show")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(lastProject == nil ? "Open a bundle to begin" : "Continue last project")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel(lastProject.map { "Continue \($0.name)" } ?? "Open a project")

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                TextField("Project name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(width: 240, height: 34)
                    .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                    .focused($nameFieldFocused)
                    .accessibilityLabel("Project name")
                Button("Create", action: createProject)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StartHome.ink)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(StartHome.lemon, in: Capsule(style: .continuous))
                    .buttonStyle(DeskPressButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button(action: openExisting) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .keyboardShortcut("o", modifiers: [.command])
                .help("Open project")
                .accessibilityLabel("Open project")
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(StartHome.dock)
    }

    private func createProject() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        #if os(macOS)
        if let url = ProjectFilePanel.save(name: name) {
            onCreate(name, url)
        }
        #else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        onCreate(name, docs.appendingPathComponent("\(name).proshow", isDirectory: true))
        #endif
    }

    private func openExisting() {
        #if os(macOS)
        if let url = ProjectFilePanel.open() {
            onOpen(url)
        }
        #else
        isImporterPresented = true
        #endif
    }
}

private enum StartHomePane {
    case home, recents
}

private enum StartRecentFilter {
    case all, week
}

private enum StartMark {
    case beam, lens, host, wave, burst, pages
}

private struct StartHeroCard: View {
    var title: String
    var subtitle: String
    var actionTitle: String
    var actionImage: String
    var fill: Color
    var ink: Color
    var art: StartMark
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                fill
                StartDoodle(kind: art, ink: ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ink.opacity(0.62))
                        .lineLimit(1)
                    Text(title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 8) {
                        Image(systemName: actionImage)
                            .font(.system(size: 10, weight: .bold))
                        Text(actionTitle)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.55), in: Capsule(style: .continuous))
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 196)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.22), radius: 8, y: 4)
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(actionTitle)
        .accessibilityHint(subtitle)
    }
}

private struct StartTileCard: View {
    var title: String
    var detail: String
    var fill: Color
    var art: StartMark
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                StartDoodle(kind: art, ink: StartHome.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(StartHome.ink)
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StartHome.ink.opacity(0.58))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .frame(height: 168)
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

private struct StartDoodle: View {
    var kind: StartMark
    var ink: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            switch kind {
            case .beam:
                var stem = Path()
                stem.move(to: CGPoint(x: w * 0.72, y: h * 0.22))
                stem.addQuadCurve(to: CGPoint(x: w * 0.88, y: h * 0.78), control: CGPoint(x: w * 1.05, y: h * 0.42))
                context.stroke(stem, with: .color(ink), lineWidth: 10)
                context.stroke(
                    Path(ellipseIn: CGRect(x: w * 0.58, y: h * 0.12, width: 36, height: 36)),
                    with: .color(ink),
                    lineWidth: 8
                )
            case .lens:
                context.stroke(
                    Path(ellipseIn: CGRect(x: w * 0.55, y: h * 0.18, width: 88, height: 88)),
                    with: .color(ink),
                    lineWidth: 10
                )
                context.fill(Path(ellipseIn: CGRect(x: w * 0.78, y: h * 0.22, width: 16, height: 16)), with: .color(ink))
                var line = Path()
                line.move(to: CGPoint(x: w * 0.62, y: h * 0.72))
                line.addLine(to: CGPoint(x: w * 0.92, y: h * 0.58))
                context.stroke(line, with: .color(ink), lineWidth: 8)
            case .host:
                context.stroke(
                    Path(ellipseIn: CGRect(x: w * 0.38, y: 8, width: 44, height: 44)),
                    with: .color(ink),
                    lineWidth: 7
                )
                var body = Path()
                body.move(to: CGPoint(x: w * 0.28, y: h * 0.62))
                body.addQuadCurve(to: CGPoint(x: w * 0.78, y: h * 0.58), control: CGPoint(x: w * 0.52, y: h * 0.28))
                context.stroke(body, with: .color(ink), lineWidth: 7)
            case .wave:
                var wave = Path()
                wave.move(to: CGPoint(x: 16, y: h * 0.42))
                wave.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.38), control: CGPoint(x: w * 0.24, y: 8))
                wave.addQuadCurve(to: CGPoint(x: w - 16, y: h * 0.48), control: CGPoint(x: w * 0.76, y: h * 0.78))
                context.stroke(wave, with: .color(ink), lineWidth: 8)
                context.fill(Path(ellipseIn: CGRect(x: w * 0.42, y: 10, width: 14, height: 14)), with: .color(ink))
            case .burst:
                let cx = w * 0.5
                let cy = h * 0.42
                for i in 0..<6 {
                    let angle = Double(i) * .pi / 3
                    var ray = Path()
                    ray.move(to: CGPoint(x: cx + cos(angle) * 8, y: cy + sin(angle) * 8))
                    ray.addLine(to: CGPoint(x: cx + cos(angle) * 34, y: cy + sin(angle) * 34))
                    context.stroke(ray, with: .color(ink), lineWidth: 7)
                }
            case .pages:
                context.stroke(
                    Path(roundedRect: CGRect(x: w * 0.22, y: 16, width: w * 0.36, height: h * 0.52), cornerRadius: 6),
                    with: .color(ink),
                    lineWidth: 6
                )
                context.stroke(
                    Path(roundedRect: CGRect(x: w * 0.42, y: 28, width: w * 0.36, height: h * 0.52), cornerRadius: 6),
                    with: .color(ink),
                    lineWidth: 6
                )
            }
        }
    }
}

#if os(macOS)
enum ProjectFilePanel {
    static func save(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(name).proshow"
        panel.title = "Create ProShow Project"
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if url.pathExtension != "proshow" {
            url = url.appendingPathExtension("proshow")
        }
        return url
    }

    static func open() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Open ProShow Project"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    static func openMedia() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .image, .audio]
        panel.title = "Add Media File"
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }
}
#endif
