import SwiftUI
import WatchKit

struct WatchLibraryView: View {
    let store: WatchStore
    @State private var position: Double = 0

    var body: some View {
        NavigationStack {
            Group {
                if store.albums.isEmpty {
                    emptyState
                } else {
                    flow
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        // The system Now Playing view controls the iPhone's Music app, crown volume included.
                        NowPlayingView()
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .accessibilityLabel("Now Playing")
                }
            }
            .alert("Crate", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    private var flow: some View {
        let albums = store.albums
        let current = albums[min(max(Int(position.rounded()), 0), albums.count - 1)]
        return VStack(spacing: 1) {
            CoverFlowView(items: albums, position: $position, isFlipped: .constant(false)) { album in
                CoverArtView(image: store.image(for: album), title: album.title, artist: album.artist, seed: album.id)
            } back: { _ in
                EmptyView()
            } onActivate: { album in
                store.play(album)
            }
            Text(current.title).font(.footnote.weight(.semibold)).lineLimit(1)
            Text(current.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .focusable()
        .modifier(CrownScrolling(position: $position, count: albums.count))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack").font(.title2)
            switch store.syncState {
            case .idle:
                Text("Sync your albums from Crate on your iPhone.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Sync Library") { store.requestLibrary() }
            case .requesting, .waitingForTransfer:
                ProgressView()
                Text("Syncing from iPhone…").font(.footnote)
            }
        }
        .padding()
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}

/// Digital Crown moves through the covers, with a detent per album.
private struct CrownScrolling: ViewModifier {
    @Binding var position: Double
    let count: Int

    func body(content: Content) -> some View {
        if count > 1 {
            content.digitalCrownRotation(
                $position,
                from: 0,
                through: Double(count - 1),
                by: 1,
                sensitivity: .low,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
        } else {
            content
        }
    }
}
