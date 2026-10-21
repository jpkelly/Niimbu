import SwiftUI

@main
struct NiimbuApp: App {
    @State private var document = LabelDocument()
    @State private var printer = PrinterStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(document)
                .environment(printer)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 560)
        .commands { AboutCommand() }
        #endif

        #if os(macOS)
        Window("About Niimbu", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        #endif
    }
}

#if os(macOS)
/// Replaces the standard About panel with the app's own page, which shows when the install expires.
private struct AboutCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Niimbu") { openWindow(id: "about") }
        }
    }
}
#endif
