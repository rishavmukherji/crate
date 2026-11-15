import SwiftUI

@main
struct CrateWatchApp: App {
    @State private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            WatchLibraryView(store: store)
        }
    }
}
