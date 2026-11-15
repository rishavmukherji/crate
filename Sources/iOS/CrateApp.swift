import SwiftUI

@main
struct CrateApp: App {
    #if targetEnvironment(simulator)
    // The Simulator has no music library to read or play.
    typealias Backend = DemoBackend
    #else
    typealias Backend = MediaLibraryBackend
    #endif

    @State private var backend: Backend
    private let watchSync: WatchSync

    init() {
        let backend = Backend()
        _backend = State(initialValue: backend)
        // Created at launch, not on first render: the watch can launch this app in the background.
        watchSync = WatchSync(backend: backend)
    }

    var body: some Scene {
        WindowGroup {
            LibraryScreen(backend: backend)
        }
    }
}
