import SwiftUI

/// The main iPhone / Mac screen: Cover Flow over the albums or playlists, with a now-playing bar.
/// Opening a playlist shows a flow of the albums its songs come from.
struct LibraryScreen<Backend: MusicBackend>: View {
    let backend: Backend

    @State private var shelf: Shelf = .albums
    @State private var openPlaylist: OpenPlaylist?
    /// Each page remembers where you were in it.
    @State private var positions: [Page: Double] = [:]
    @State private var isFlipped = false
    /// Folds the covers away while the flow changes to another list (see `changePage`).
    @State private var spread: Double = 1
    @State private var isChangingPage = false
    /// The shelf picked in the picker while the flow is still folding away from the old one.
    @State private var pendingShelf: Shelf?
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// A phone in landscape: everything below the flow shares one row so the covers get the height.
    private var isShort: Bool { verticalSizeClass == .compact }
    #else
    private var isShort: Bool { false }
    #endif

    private static var artworkSide: CGFloat { 600 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch backend.state {
            case .idle, .loading:
                ProgressView("Loading your library…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't open your library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await backend.load() } }
                }
            case .loaded:
                VStack(spacing: 0) {
                    header
                        .frame(height: 32)
                        .padding(.top, isShort ? 2 : 8)
                        .padding(.horizontal)
                        .animation(.easeInOut(duration: 0.25), value: page)

                    if items.isEmpty {
                        ContentUnavailableView(
                            "No \(shelf.rawValue.lowercased()) yet",
                            systemImage: "music.note",
                            description: Text("Add music to your library in the Music app, then reopen Crate.")
                        )
                    } else {
                        library
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await backend.load() }
        .alert("Something went wrong", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private struct OpenPlaylist {
        let playlist: Album
        /// The playlist's songs grouped by album, computed once when it opens.
        let albums: [Album]
    }

    private enum Page: Hashable {
        case shelf(Shelf)
        case playlist(Album.ID)
    }

    private var page: Page {
        openPlaylist.map { .playlist($0.playlist.id) } ?? .shelf(shelf)
    }

    private var items: [Album] { openPlaylist?.albums ?? backend.items(on: shelf) }

    private var position: Double {
        get { positions[page] ?? 0 }
        nonmutating set { positions[page] = newValue }
    }

    @ViewBuilder
    private var header: some View {
        if let openPlaylist {
            ZStack {
                Text(openPlaylist.playlist.title).font(.headline).lineLimit(1).padding(.horizontal, 110)
                HStack {
                    Button { closePlaylist() } label: {
                        Label("Playlists", systemImage: "chevron.left")
                    }
                    Spacer()
                    Button {
                        perform { try await backend.play(openPlaylist.playlist, from: nil) }
                    } label: {
                        Label("Play Playlist", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.bordered)
            }
            .transition(.opacity)
        } else {
            Picker("Show", selection: shelfBinding) {
                ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .transition(.opacity)
        }
    }

    private var positionBinding: Binding<Double> {
        Binding(get: { position }, set: { position = $0 })
    }

    private var shelfBinding: Binding<Shelf> {
        Binding(
            get: { pendingShelf ?? shelf },
            set: { newShelf in
                guard newShelf != shelf, !isChangingPage else { return }
                pendingShelf = newShelf
                changePage {
                    shelf = newShelf
                    pendingShelf = nil
                }
            }
        )
    }

    private var library: some View {
        let albums = items
        let current = albums[currentIndex]
        return VStack(spacing: isShort ? 6 : 14) {
            CoverFlowView(items: albums, position: positionBinding, isFlipped: $isFlipped, spread: spread) { album in
                LoadingCover(backend: backend, album: album, side: Self.artworkSide)
            } back: { album in
                TrackListBack(
                    album: album,
                    nowPlaying: backend.nowPlaying,
                    playAllTitle: openPlaylist == nil ? "Play Album" : "Play from Here",
                    onPlay: { track in play(album, from: track) },
                    onClose: { setFlipped(false) }
                )
            } onActivate: { album in
                activate(album)
            }
            .allowsHitTesting(!isChangingPage)

            if isShort {
                HStack(spacing: 16) {
                    caption(for: current, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    nowPlayingBar.frame(maxWidth: 440)
                }
            } else {
                caption(for: current, alignment: .center)

                if albums.count > 1 {
                    Slider(value: scrubBinding, in: 0...Double(albums.count - 1))
                        .tint(.white.opacity(0.6))
                        .frame(maxWidth: 520)
                }

                nowPlayingBar.frame(maxWidth: 620)
            }
        }
        .padding(isShort ? EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16) : EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.return) {
            if isFlipped { setFlipped(false) } else { activate(current) }
            return .handled
        }
        .onKeyPress(.escape) {
            if isFlipped { setFlipped(false) } else { closePlaylist() }
            return .handled
        }
        .onKeyPress(.space) {
            perform { try await backend.togglePlayPause() }
            return .handled
        }
        #if os(macOS)
        .onScrollWheel { delta in
            guard !isFlipped else { return }
            position = min(max(position - delta, 0), Double(albums.count - 1))
        }
        #endif
    }

    private func caption(for album: Album, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(album.title).font(.headline)
            Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private var nowPlayingBar: some View {
        NowPlayingBar(
            nowPlaying: backend.nowPlaying,
            onPrevious: { perform { try await backend.skipToPrevious() } },
            onPlayPause: { perform { try await backend.togglePlayPause() } },
            onNext: { perform { try await backend.skipToNext() } }
        )
    }

    private var currentIndex: Int {
        min(max(Int(position.rounded()), 0), items.count - 1)
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { position },
            set: { newValue in
                isFlipped = false
                position = newValue.rounded()
            }
        )
    }

    private func step(_ delta: Int) {
        setFlipped(false)
        let target = min(max(currentIndex + delta, 0), items.count - 1)
        withAnimation(.coverFlowSettle) { position = Double(target) }
    }

    /// The centered cover was chosen: a playlist on the Playlists shelf opens; anything else flips.
    private func activate(_ album: Album) {
        guard openPlaylist == nil, shelf == .playlists else { return setFlipped(true) }
        let opened = OpenPlaylist(playlist: album, albums: album.songsByAlbum())
        changePage { openPlaylist = opened }
    }

    private func closePlaylist() {
        guard openPlaylist != nil else { return }
        changePage { openPlaylist = nil }
    }

    /// Shows another list in the flow: the covers fold in behind the centered one, the list changes,
    /// and the new covers fan out from behind its centered cover. A playlist's cover is usually its
    /// first album's, so opening one looks like that cover opening up into the playlist's albums.
    private func changePage(_ change: @escaping () -> Void) {
        guard !isChangingPage else { return }
        setFlipped(false)
        guard !reduceMotion else { return change() }
        isChangingPage = true
        withAnimation(.coverFlowFold) {
            spread = 0
        } completion: {
            change()
            // Let the new list render folded before it fans out.
            DispatchQueue.main.async {
                withAnimation(.coverFlowFan) {
                    spread = 1
                } completion: {
                    isChangingPage = false
                }
            }
        }
    }

    /// Inside an open playlist, songs play as part of the playlist; elsewhere as part of their album.
    private func play(_ album: Album, from track: Track?) {
        if let playlist = openPlaylist?.playlist {
            perform { try await backend.play(playlist, from: track ?? album.tracks.first) }
        } else {
            perform { try await backend.play(album, from: track) }
        }
    }

    private func setFlipped(_ flipped: Bool) {
        guard flipped != isFlipped else { return }
        withAnimation(.coverFlowFlip) { isFlipped = flipped }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() } catch { errorMessage = error.localizedDescription }
        }
    }

    private var alertMessage: String? { errorMessage ?? backend.playbackError }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                guard !isPresented else { return }
                errorMessage = nil
                backend.playbackError = nil
            }
        )
    }
}

/// A cover whose artwork loads in the background; the generated cover shows until it arrives.
private struct LoadingCover<Backend: MusicBackend>: View {
    let backend: Backend
    let album: Album
    let side: CGFloat

    @State private var image: PlatformImage?

    var body: some View {
        // Art loaded earlier shows at once, so covers don't flash when the flow changes lists.
        CoverArtView(image: image ?? backend.cachedArtwork(for: album, side: side),
                     title: album.title, artist: album.artist, seed: album.id)
            // Always store the result in state, cached or not: a cover and its reflection are separate
            // copies of this view, and a copy that skipped the store would never redraw once the other filled the cache.
            .task(id: album.id) {
                image = backend.cachedArtwork(for: album, side: side)
                if image == nil { image = await backend.artwork(for: album, side: side) }
            }
    }
}

/// The back of a flipped cover: the album's tracklist.
struct TrackListBack: View {
    let album: Album
    let nowPlaying: NowPlaying?
    let playAllTitle: String
    let onPlay: (Track?) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).font(.system(size: 12, weight: .bold))
                    Text(album.artist).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tracklist")
            }
            .padding(8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { number, track in
                        Button { onPlay(track) } label: {
                            trackRow(number: number + 1, track: track)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button { onPlay(nil) } label: {
                Label(playAllTitle, systemImage: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(8)
        }
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func trackRow(number: Int, track: Track) -> some View {
        let isCurrent = nowPlaying?.trackID == track.id
        return HStack(spacing: 6) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 8))
                } else {
                    Text("\(number)")
                }
            }
            .frame(width: 18, alignment: .trailing)
            .foregroundStyle(.secondary)
            Text(track.title).lineLimit(1)
            Spacer(minLength: 4)
            Text(Duration.seconds(track.duration).formatted(.time(pattern: .minuteSecond)))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 10).monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct NowPlayingBar: View {
    let nowPlaying: NowPlaying?
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(nowPlaying?.title ?? "Not Playing").font(.subheadline.weight(.semibold))
                if let nowPlaying {
                    Text("\(nowPlaying.artist) — \(nowPlaying.albumTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer()
            Button(action: onPrevious) { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Button(action: onPlayPause) {
                Image(systemName: nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill").font(.title2)
            }
            .accessibilityLabel(nowPlaying?.isPlaying == true ? "Pause" : "Play")
            Button(action: onNext) { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
