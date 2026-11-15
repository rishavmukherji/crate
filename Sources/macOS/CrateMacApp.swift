import SwiftUI

@main
struct CrateMacApp: App {
    @State private var backend = MusicAppBackend()

    var body: some Scene {
        WindowGroup("Crate") {
            LibraryScreen(backend: backend)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 680)
    }
}
