import SwiftUI

/// Stand-in library for the iOS Simulator and SwiftUI previews, which have no music library.
/// "Playback" only updates `nowPlaying`.
@Observable
@MainActor
final class DemoBackend: MusicBackend {
    private(set) var albums: [Album] = []
    private(set) var playlists: [Album] = []
    private(set) var state: LibraryState = .idle
    private(set) var nowPlaying: NowPlaying?
    var playbackError: String?

    @ObservationIgnored private let gate = LoadGate()
    @ObservationIgnored private var queue: (album: Album, index: Int)?

    func load() async {
        await gate.run { [weak self] in
            guard let self else { return false }
            state = .loading
            albums = Self.sampleAlbums()
            playlists = Self.samplePlaylists(from: albums)
            state = .loaded
            return true
        }
    }

    func artwork(for album: Album, side: CGFloat) async -> PlatformImage? { nil }
    func cachedArtwork(for album: Album, side: CGFloat) -> PlatformImage? { nil }

    func play(_ album: Album, from track: Track?) async throws {
        let index = track.flatMap { track in album.tracks.firstIndex(of: track) } ?? 0
        queue = (album, index)
        updateNowPlaying(isPlaying: true)
    }

    func togglePlayPause() async throws {
        guard let nowPlaying else { throw PlayerError.nothingQueued }
        updateNowPlaying(isPlaying: !nowPlaying.isPlaying)
    }

    func skipToNext() async throws { try move(by: 1) }
    func skipToPrevious() async throws { try move(by: -1) }

    private func move(by delta: Int) throws {
        guard let queue else { throw PlayerError.nothingQueued }
        self.queue = (queue.album, min(max(queue.index + delta, 0), queue.album.tracks.count - 1))
        updateNowPlaying(isPlaying: true)
    }

    private func updateNowPlaying(isPlaying: Bool) {
        guard let queue else { nowPlaying = nil; return }
        let track = queue.album.tracks[queue.index]
        nowPlaying = NowPlaying(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            albumTitle: queue.album.title,
            albumID: queue.album.id,
            isPlaying: isPlaying
        )
    }

    private static func samplePlaylists(from albums: [Album]) -> [Album] {
        let tracks = albums.flatMap(\.tracks)
        return ["Favorite Songs", "Road Trip", "Late Night", "Focus"].enumerated().map { index, name in
            let picks = tracks.enumerated().filter { $0.offset % (index + 3) == 0 }.map(\.element)
            return .playlist(id: "demo-playlist-\(index)", title: name, tracks: picks)
        }
    }

    private static func sampleAlbums() -> [Album] {
        let titles = ["Neon Harbor", "Glass Orchard", "Paper Satellites", "Low Tide Radio", "Copper Sky",
                      "Velvet Static", "Night Garden", "Salt & Signal", "Northern Lines", "Slow Comet",
                      "Ember Season", "Quiet Machines", "Lantern Field", "Blue Hour Tapes", "Wild Geometry",
                      "Second Summer", "Echo Valley", "Midnight Atlas", "Foxglove", "Open Water"]
        let artists = ["The Lighthouses", "Mara Vale", "Kite Theory", "Sundial", "Okon & the Owls"]
        return titles.enumerated().map { index, title in
            let artist = artists[index % artists.count]
            let tracks = (1...(8 + index % 5)).map { number in
                Track(id: "demo-\(index)-\(number)", title: "\(title) Pt. \(number)", artist: artist,
                      duration: TimeInterval(150 + (number * 37) % 140),
                      albumID: "demo-\(index)", albumTitle: title, albumArtist: artist)
            }
            return Album.album(of: tracks)
        }
    }
}
