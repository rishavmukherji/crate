import SwiftUI

/// An album or a playlist: a titled, ordered list of tracks shown as one cover.
struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]

    /// The album that `tracks` (non-empty, all from one album) come from.
    static func album(of tracks: [Track]) -> Album {
        Album(id: tracks[0].albumID, title: tracks[0].albumTitle, artist: tracks[0].albumArtist, tracks: tracks)
    }

    /// A playlist; `artist` is where an album shows its artist.
    static func playlist(id: String, title: String, tracks: [Track]) -> Album {
        let count = tracks.count == 1 ? "1 song" : "\(tracks.count.formatted()) songs"
        return Album(id: id, title: title, artist: "Playlist · \(count)", tracks: tracks)
    }
}

/// Which collections the flow shows.
enum Shelf: String, CaseIterable, Identifiable {
    case albums = "Albums"
    case playlists = "Playlists"

    var id: Self { self }
}

struct Track: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let duration: TimeInterval
    /// The album the song comes from, even when it's listed in a playlist.
    let albumID: String
    let albumTitle: String
    let albumArtist: String
}

extension Album {
    /// This list's songs grouped by the album each comes from, in order of first appearance.
    /// Groups use the real album's ID, so they show that album's cover.
    func songsByAlbum() -> [Album] {
        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for track in tracks {
            if groups[track.albumID] == nil { order.append(track.albumID) }
            groups[track.albumID, default: []].append(track)
        }
        return order.compactMap { id in groups[id].map(Album.album(of:)) }
    }
}

struct NowPlaying: Hashable {
    var trackID: String?
    var title: String
    var artist: String
    var albumTitle: String
    /// Set when the playing track belongs to an album Crate knows about.
    var albumID: String?
    var isPlaying: Bool
}

enum LibraryState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum PlayerError: LocalizedError {
    case albumNotFound
    case nothingQueued
    case libraryUnavailable(String)
    case musicApp(String)

    var errorDescription: String? {
        switch self {
        case .albumNotFound: "That album is no longer in your library."
        case .nothingQueued: "Nothing is queued. Pick an album first."
        case .libraryUnavailable(let reason): reason
        case .musicApp(let message): "The Music app reported an error: \(message)"
        }
    }
}

/// A music library plus the player that plays it. One implementation per platform.
@MainActor
protocol MusicBackend: AnyObject, Observable {
    var albums: [Album] { get }
    /// The library's playlists, Favorite Songs first when the platform can identify it.
    var playlists: [Album] { get }
    var state: LibraryState { get }
    var nowPlaying: NowPlaying? { get }
    /// Errors from playback the user didn't directly trigger (e.g. auto-advancing to the next track).
    var playbackError: String? { get set }

    /// Loads the library. Concurrent and repeated calls share one load; a failed load can be retried.
    func load() async
    /// Cover art at `side` points, or nil when the album has none.
    func artwork(for album: Album, side: CGFloat) async -> PlatformImage?
    /// Art that `artwork(for:side:)` already loaded, without waiting; nil when it hasn't.
    func cachedArtwork(for album: Album, side: CGFloat) -> PlatformImage?
    func play(_ album: Album, from track: Track?) async throws
    func togglePlayPause() async throws
    func skipToNext() async throws
    func skipToPrevious() async throws
}

extension MusicBackend {
    func items(on shelf: Shelf) -> [Album] {
        switch shelf {
        case .albums: albums
        case .playlists: playlists
        }
    }
}

/// Runs a load once; callers arriving mid-load await it. A failed run (returns false) is forgotten so it can be retried.
@MainActor
final class LoadGate {
    private var task: Task<Bool, Never>?

    func run(_ operation: @escaping @MainActor () async -> Bool) async {
        if let task {
            _ = await task.value
            return
        }
        let task = Task { await operation() }
        self.task = task
        if await task.value == false { self.task = nil }
    }
}
