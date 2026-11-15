import MediaPlayer
import SwiftUI

/// The device's music library (MediaPlayer), played through the system Music player,
/// so playback continues in the background and shows up in Control Center and on the watch.
@Observable
@MainActor
final class MediaLibraryBackend: MusicBackend {
    private(set) var albums: [Album] = []
    private(set) var playlists: [Album] = []
    private(set) var state: LibraryState = .idle
    private(set) var nowPlaying: NowPlaying?
    var playbackError: String?

    @ObservationIgnored private let player = MPMusicPlayerController.systemMusicPlayer
    /// Every song Crate lists, so any album, playlist or part of one can be played or shown.
    @ObservationIgnored private var mediaItems: [Track.ID: MPMediaItem] = [:]
    @ObservationIgnored private let artworkCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private let gate = LoadGate()
    @ObservationIgnored private var playerObservers: [NSObjectProtocol] = []

    func load() async {
        await gate.run { [weak self] in await self?.performLoad() ?? false }
    }

    private func performLoad() async -> Bool {
        state = .loading
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            state = .failed("Crate needs access to your media library. Turn on Settings › Apps › Crate › Media & Apple Music, then try again.")
            return false
        }
        startObservingPlayer()
        let library = await Task.detached(priority: .userInitiated) { Self.readLibrary() }.value
        mediaItems = library.mediaItems
        albums = library.albums
        playlists = library.playlists
        state = .loaded
        return true
    }

    nonisolated private static func readLibrary() -> (
        albums: [Album], playlists: [Album], mediaItems: [Track.ID: MPMediaItem]
    ) {
        var albums: [Album] = []
        var mediaItems: [Track.ID: MPMediaItem] = [:]
        for group in MPMediaQuery.albums().collections ?? [] {
            let items = group.items.sorted {
                ($0.discNumber, $0.albumTrackNumber) < ($1.discNumber, $1.albumTrackNumber)
            }
            guard !items.isEmpty else { continue }
            albums.append(Album.album(of: items.map(track)))
            for item in items { mediaItems[String(item.persistentID)] = item }
        }

        // Includes Favorite Songs, which the Music app keeps as a playlist.
        var playlists: [Album] = []
        for playlist in MPMediaQuery.playlists().collections as? [MPMediaPlaylist] ?? [] {
            let items = playlist.items.filter { $0.mediaType.contains(.music) }
            guard !items.isEmpty else { continue }
            let id = "playlist-\(playlist.persistentID)"
            playlists.append(.playlist(id: id, title: playlist.name ?? "Untitled Playlist", tracks: items.map(track)))
            for item in items { mediaItems[String(item.persistentID)] = item }
        }
        albums.sort {
            let byArtist = $0.artist.localizedStandardCompare($1.artist)
            return byArtist == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : byArtist == .orderedAscending
        }
        return (albums, playlists, mediaItems)
    }

    nonisolated private static func track(_ item: MPMediaItem) -> Track {
        Track(id: String(item.persistentID), title: item.title ?? "Untitled",
              artist: item.artist ?? "", duration: item.playbackDuration,
              albumID: String(item.albumPersistentID),
              albumTitle: item.albumTitle ?? "Unknown Album",
              albumArtist: item.albumArtist ?? item.artist ?? "Unknown Artist")
    }

    func cachedArtwork(for album: Album, side: CGFloat) -> PlatformImage? {
        artworkCache.object(forKey: Self.artworkKey(album, side: side))
    }

    private static func artworkKey(_ album: Album, side: CGFloat) -> NSString {
        "\(album.id)-\(Int(side))" as NSString
    }

    func artwork(for album: Album, side: CGFloat) async -> PlatformImage? {
        let key = Self.artworkKey(album, side: side)
        if let cached = artworkCache.object(forKey: key) { return cached }
        // A playlist's first song can lack art while the next ones have it; big playlists only check the start.
        let items = album.tracks.prefix(20).lazy.compactMap { self.mediaItems[$0.id] }
        guard let image = items.compactMap({ $0.artwork?.image(at: CGSize(width: side, height: side)) }).first
        else { return nil }
        artworkCache.setObject(image, forKey: key)
        return image
    }

    func play(_ album: Album, from track: Track?) async throws {
        let items = album.tracks.compactMap { mediaItems[$0.id] }
        guard !items.isEmpty else { throw PlayerError.albumNotFound }
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: items))
        if let track {
            descriptor.startItem = items.first { String($0.persistentID) == track.id }
        }
        player.shuffleMode = .off
        player.setQueue(with: descriptor)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.prepareToPlay { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        player.play()
    }

    func togglePlayPause() async throws {
        guard player.nowPlayingItem != nil else { throw PlayerError.nothingQueued }
        if player.playbackState == .playing { player.pause() } else { player.play() }
    }

    func skipToNext() async throws {
        guard player.nowPlayingItem != nil else { throw PlayerError.nothingQueued }
        player.skipToNextItem()
    }

    func skipToPrevious() async throws {
        guard player.nowPlayingItem != nil else { throw PlayerError.nothingQueued }
        // Matches the Music app: restart the song unless it has only just begun.
        if player.currentPlaybackTime > 3 { player.skipToBeginning() } else { player.skipToPreviousItem() }
    }

    private func startObservingPlayer() {
        guard playerObservers.isEmpty else { return }
        player.beginGeneratingPlaybackNotifications()
        let names: [Notification.Name] = [
            .MPMusicPlayerControllerNowPlayingItemDidChange,
            .MPMusicPlayerControllerPlaybackStateDidChange,
        ]
        playerObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshNowPlaying() }
            }
        }
        refreshNowPlaying()
    }

    private func refreshNowPlaying() {
        guard let item = player.nowPlayingItem else {
            nowPlaying = nil
            return
        }
        nowPlaying = NowPlaying(
            trackID: String(item.persistentID),
            title: item.title ?? "Untitled",
            artist: item.artist ?? "",
            albumTitle: item.albumTitle ?? "",
            albumID: String(item.albumPersistentID),
            isPlaying: player.playbackState == .playing
        )
    }
}
