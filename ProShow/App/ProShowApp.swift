import SwiftUI

@main
struct ProShowApp: App {
    @State private var controller = ShowController.loadSample()
    #if os(macOS)
    @StateObject private var audienceWindow = AudienceWindowController()
    #endif
    @State private var showAudienceSheet = false

    var body: some Scene {
        WindowGroup("ProShow") {
            RootView(
                controller: controller,
                onOpenAudienceWindow: {
                    #if os(macOS)
                    audienceWindow.open(controller: controller)
                    #else
                    showAudienceSheet = true
                    #endif
                }
            )
            #if os(iOS)
            .fullScreenCover(isPresented: $showAudienceSheet) {
                iOSAudienceCover(controller: controller, isPresented: $showAudienceSheet)
            }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Show") {
                Button("Go Live") { controller.goLive() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Next Slide") { controller.advance() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Previous Slide") { controller.goPrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button(controller.isAudienceCleared ? "Restore Audience" : "Clear Audience") {
                    if controller.isAudienceCleared {
                        controller.restoreAudience()
                    } else {
                        controller.clearAudience()
                    }
                }
                .keyboardShortcut("b", modifiers: [])
                Divider()
                Button("Open Audience Window") {
                    audienceWindow.open(controller: controller)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Reload Sample Show") {
                    controller.reloadSample()
                }
            }
        }
        #endif

        #if os(macOS)
        Settings {
            Form {
                LabeledContent("Bundle ID", value: "com.kaleel.proshow")
                LabeledContent("Product", value: "ProShow")
                Text("Original Swift codebase. FreeShow is feature reference only (GPL) — not shipped here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 420)
            .padding()
        }
        #endif
    }
}

struct RootView: View {
    @Bindable var controller: ShowController
    var onOpenAudienceWindow: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            OperatorView(controller: controller, onOpenAudienceWindow: onOpenAudienceWindow)
                .navigationTitle("ProShow")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { controller.goPrevious() } label: {
                            Image(systemName: "backward.fill")
                        }
                        Button { controller.goLive() } label: {
                            Label("Go Live", systemImage: "arrow.up.right.circle.fill")
                        }
                        Button { controller.advance() } label: {
                            Image(systemName: "forward.fill")
                        }
                        Spacer()
                        Button("Audience") { onOpenAudienceWindow() }
                    }
                }
        }
        #else
        OperatorView(controller: controller, onOpenAudienceWindow: onOpenAudienceWindow)
        #endif
    }
}

#if os(iOS)
private struct iOSAudienceCover: View {
    @Bindable var controller: ShowController
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AudienceView(slide: controller.liveSlide, showsChrome: true)
                .ignoresSafeArea()

            Button("Done") { isPresented = false }
                .padding(16)
                .buttonStyle(.borderedProminent)
        }
        .statusBarHidden(true)
    }
}
#endif
