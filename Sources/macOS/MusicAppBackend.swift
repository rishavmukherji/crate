import AppKit
import ImageIO
import iTunesLibrary
import SwiftUI

/// Reads the Music app's library (iTunesLibrary) and plays through the Music app (Apple Events).
///
/// The Music app's scripting interface can't queue an album without creating a playlist in the
/// user's library, so Crate plays one track at a time (`with once`) and starts the next track
/// itself when the Music app reports the previous one finished.
@Observable
@MainActor
final class MusicAppBackend: MusicBackend {
    private(set) var albums: [Album] = []
    private(set) var playlists: [Album] = []
    private(set) var state: LibraryState = .idle
    private(set) var nowPlaying: NowPlaying?
    var playbackError: String?

    /// The song whose artwork stands for each album or playlist.
    @ObservationIgnored private var artworkItems: [Album.ID: ITLibMediaItem] = [:]
    /// Songs that are only in playlists, not in the library itself: track ID → a playlist holding it.
    @ObservationIgnored private var playlistOnlyTracks: [String: String] = [:]
    @ObservationIgnored private let artworkCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private let gate = LoadGate()
    @ObservationIgnored private let music = MusicAppScripting()
    @ObservationIgnored private lazy var musicArtwork: MusicAppArtwork = {
        let artwork = MusicAppArtwork(scripting: music)
        artwork.onFirstError = { [weak self] error in
            self?.playbackError = "Crate couldn't get album art from the Music app: \(error.localizedDescription) If Crate isn't allowed to control Music, turn it on in System Settings › Privacy & Security › Automation."
        }
        return artwork
    }()
    @ObservationIgnored private var playerObserver: NSObjectProtocol?

    /// The album Crate is stepping through, if Crate started the current playback.
    @ObservationIgnored private var queue: (album: Album, index: Int)?
    /// Track Crate just asked the Music app to play; state changes before it starts are transitional.
    @ObservationIgnored private var pendingTrackID: String?
    @ObservationIgnored private var lastPlayingTrackID: String?

    func load() async {
        await gate.run { [weak self] in await self?.performLoad() ?? false }
    }

    private func performLoad() async -> Bool {
        state = .loading
        do {
            let library = try await Task.detached(priority: .userInitiated) { try Self.readLibrary() }.value
            albums = library.albums
            playlists = library.playlists
            artworkItems = library.artworkItems
            playlistOnlyTracks = library.playlistOnlyTracks
            state = .loaded
            startObservingPlayer()
            return true
        } catch {
            state = .failed("Crate couldn't read your Music library (\(error.localizedDescription)). Allow access in System Settings › Privacy & Security › Media & Apple Music, then try again.")
            return false
        }
    }

    private struct LibrarySnapshot {
        var albums: [Album] = []
        var playlists: [Album] = []
        var artworkItems: [Album.ID: ITLibMediaItem] = [:]
        var playlistOnlyTracks: [String: String] = [:]
    }

    nonisolated private static func readLibrary() throws -> LibrarySnapshot {
        let library = try ITLibrary(apiVersion: "1.1")
        var groups: [UInt64: [ITLibMediaItem]] = [:]
        for item in library.allMediaItems where item.mediaKind == .kindSong {
            groups[item.album.persistentID.uint64Value, default: []].append(item)
        }
        var albums: [Album] = []
        var artworkItems: [Album.ID: ITLibMediaItem] = [:]
        for items in groups.values {
            let sorted = items.sorted { ($0.album.discNumber, $0.trackNumber) < ($1.album.discNumber, $1.trackNumber) }
            let album = Album.album(of: sorted.map(track))
            albums.append(album)
            artworkItems[album.id] = artworkItem(sorted)
        }
        albums.sort {
            let byArtist = $0.artist.localizedStandardCompare($1.artist)
            return byArtist == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : byArtist == .orderedAscending
        }

        var playlists: [Album] = []
        for playlist in library.allPlaylists where playlist.isVisible && !playlist.isPrimary && playlist.kind != .folder {
            // Skip the built-in media lists (Music, Movies, Podcasts…) but keep Favorite Songs.
            guard playlist.distinguishedKind == .kindNone || playlist.distinguishedKind == .kindLovedSongs else { continue }
            let songs = playlist.items.filter { $0.mediaKind == .kindSong }
            guard !songs.isEmpty else { continue }
            let id = "playlist-\(playlist.persistentID.uint64Value)"
            let album = Album.playlist(id: id, title: playlist.name, tracks: songs.map(track))
            if playlist.distinguishedKind == .kindLovedSongs { playlists.insert(album, at: 0) } else { playlists.append(album) }
            // The cover of the playlist's first album: opening the playlist starts from that album.
            artworkItems[id] = artworkItems[String(songs[0].album.persistentID.uint64Value)] ?? artworkItem(songs)
        }
        return LibrarySnapshot(
            albums: albums,
            playlists: playlists,
            artworkItems: artworkItems,
            playlistOnlyTracks: playlistOnlyTracks(library)
        )
    }

    /// With "Add Playlist Songs" off, songs in playlists needn't be in the library, and the Music app
    /// only finds them through a playlist that holds them.
    nonisolated private static func playlistOnlyTracks(_ library: ITLibrary) -> [String: String] {
        guard let primary = library.allPlaylists.first(where: \.isPrimary) else { return [:] }
        let inLibrary = Set(primary.items.map(\.persistentID))
        var homes: [String: String] = [:]
        for playlist in library.allPlaylists where !playlist.isPrimary && playlist.kind != .folder {
            let playlistID = hexID(playlist.persistentID)
            for item in playlist.items where !inLibrary.contains(item.persistentID) {
                let trackID = hexID(item.persistentID)
                if homes[trackID] == nil { homes[trackID] = playlistID }
            }
        }
        return homes
    }

    private func location(of trackID: String) -> MusicAppScripting.TrackLocation {
        MusicAppScripting.TrackLocation(trackID: trackID, playlistID: playlistOnlyTracks[trackID])
    }

    nonisolated private static func track(_ item: ITLibMediaItem) -> Track {
        Track(id: hexID(item.persistentID), title: item.title, artist: item.artist?.name ?? "",
              duration: TimeInterval(item.totalTime) / 1000,
              albumID: String(item.album.persistentID.uint64Value),
              albumTitle: item.album.title ?? "Unknown Album",
              albumArtist: item.album.albumArtist ?? item.artist?.name ?? "Unknown Artist")
    }

    nonisolated private static func artworkItem(_ items: [ITLibMediaItem]) -> ITLibMediaItem {
        items.first(where: \.hasArtworkAvailable) ?? items[0]
    }

    /// The Music app identifies tracks by a 16-digit uppercase hex persistent ID.
    nonisolated private static func hexID(_ persistentID: NSNumber) -> String {
        String(format: "%016llX", persistentID.uint64Value)
    }

    func cachedArtwork(for album: Album, side: CGFloat) -> PlatformImage? {
        artworkItems[album.id].flatMap { artworkCache.object(forKey: Self.artworkKey($0, side: side)) }
    }

    /// Keyed by the song the art comes from, so a playlist and the album it borrows its cover from share it.
    nonisolated private static func artworkKey(_ item: ITLibMediaItem, side: CGFloat) -> NSString {
        "\(hexID(item.persistentID))-\(Int(side))" as NSString
    }

    func artwork(for album: Album, side: CGFloat) async -> PlatformImage? {
        guard let item = artworkItems[album.id] else { return nil }
        let key = Self.artworkKey(item, side: side)
        if let cached = artworkCache.object(forKey: key) { return cached }
        // Songs stored on this Mac carry their art in the library; streamed songs get it from the Music app.
        let data: Data?
        if let local = item.artwork?.imageData {
            data = local
        } else {
            data = await musicArtwork.imageData(for: location(of: Self.hexID(item.persistentID)))
        }
        guard let data, let image = await Self.thumbnail(data, side: side) else { return nil }
        artworkCache.setObject(image, forKey: key)
        return image
    }

    nonisolated private static func thumbnail(_ data: Data, side: CGFloat) async -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: side * 2,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: side, height: side))
    }

    func play(_ album: Album, from track: Track?) async throws {
        let index = track.flatMap { album.tracks.firstIndex(of: $0) } ?? 0
        queue = (album, index)
        try await playQueuedTrack()
    }

    func togglePlayPause() async throws {
        try await music.playPause()
    }

    func skipToNext() async throws {
        guard let queue else { return try await music.nextTrack() }
        guard queue.index + 1 < queue.album.tracks.count else { throw PlayerError.nothingQueued }
        self.queue = (queue.album, queue.index + 1)
        try await playQueuedTrack()
    }

    func skipToPrevious() async throws {
        guard let queue else { return try await music.previousTrack() }
        self.queue = (queue.album, max(queue.index - 1, 0))
        try await playQueuedTrack()
    }

    private func playQueuedTrack() async throws {
        guard let queue else { throw PlayerError.nothingQueued }
        let trackID = queue.album.tracks[queue.index].id
        pendingTrackID = trackID
        do {
            try await music.play(location(of: trackID))
        } catch {
            pendingTrackID = nil
            self.queue = nil
            throw error
        }
    }

    private func startObservingPlayer() {
        guard playerObserver == nil else { return }
        playerObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handlePlayerInfo(info) }
        }
    }

    private func handlePlayerInfo(_ info: [AnyHashable: Any]) {
        let playerState = info["Player State"] as? String
        let trackID = (info["PersistentID"] as? NSNumber).map(Self.hexID)

        switch playerState {
        case "Playing", "Paused":
            if pendingTrackID != nil && trackID == pendingTrackID { pendingTrackID = nil }
            if let current = queue, pendingTrackID == nil {
                if let index = current.album.tracks.firstIndex(where: { $0.id == trackID }) {
                    queue = (current.album, index)
                } else {
                    // Someone started something else in the Music app; stop managing playback.
                    queue = nil
                }
            }
            if playerState == "Playing" { lastPlayingTrackID = trackID }
            nowPlaying = NowPlaying(
                trackID: trackID,
                title: info["Name"] as? String ?? "",
                artist: info["Artist"] as? String ?? "",
                albumTitle: info["Album"] as? String ?? "",
                albumID: queue?.album.id,
                isPlaying: playerState == "Playing"
            )
        case "Stopped":
            nowPlaying?.isPlaying = false
            guard pendingTrackID == nil, let queue,
                  lastPlayingTrackID == queue.album.tracks[queue.index].id
            else { return }
            lastPlayingTrackID = nil
            // The track Crate played `once` has finished: continue the album.
            guard queue.index + 1 < queue.album.tracks.count else {
                self.queue = nil
                return
            }
            self.queue = (queue.album, queue.index + 1)
            Task {
                do {
                    try await playQueuedTrack()
                } catch {
                    playbackError = error.localizedDescription
                }
            }
        default:
            break
        }
    }
}

/// Apple Events to the Music app. Scripts run one at a time on a private queue, off the main thread.
final class MusicAppScripting: Sendable {
    private let queue = DispatchQueue(label: "\(Bundle.main.appIdentifier).scripting", qos: .userInitiated)

    /// Where the Music app can find a track. IDs are hex persistent IDs; they are spliced into scripts.
    struct TrackLocation: Hashable, Sendable {
        let trackID: String
        /// A playlist holding the track, for tracks that aren't in the library itself.
        let playlistID: String?
    }

    func play(_ track: TrackLocation) async throws {
        try await run(script(for: track, "play t with once")) { _ in }
    }

    /// The track's artwork as encoded image data, or nil when it has none.
    func artworkData(_ track: TrackLocation) async throws -> Data? {
        let source = script(for: track, """
            if (count of artworks of t) is 0 then return missing value
            return raw data of artwork 1 of t
            """)
        return try await run(source) { result in
            // `missing value` comes back as a type descriptor; artwork comes back as raw data.
            result.descriptorType == typeData ? result.data : nil
        }
    }

    func playPause() async throws { try await run(#"tell application "Music" to playpause"#) { _ in } }
    func nextTrack() async throws { try await run(#"tell application "Music" to next track"#) { _ in } }
    func previousTrack() async throws { try await run(#"tell application "Music" to back track"#) { _ in } }

    private func script(for track: TrackLocation, _ body: String) -> String {
        let ids = [track.trackID] + (track.playlistID.map { [$0] } ?? [])
        precondition(ids.allSatisfy { $0.allSatisfy(\.isHexDigit) }, "Track locations use hex persistent IDs")
        let container = track.playlistID.map { #"(first playlist whose persistent ID is "\#($0)")"# } ?? "library playlist 1"
        return """
        tell application "Music"
            set t to first track of \(container) whose persistent ID is "\(track.trackID)"
            \(body)
        end tell
        """
    }

    private func run<Result: Sendable>(
        _ source: String,
        _ transform: @escaping @Sendable (NSAppleEventDescriptor) -> Result
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    return continuation.resume(throwing: PlayerError.musicApp("Crate built an invalid script."))
                }
                var errorInfo: NSDictionary?
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
                    continuation.resume(throwing: PlayerError.musicApp(message))
                } else {
                    continuation.resume(returning: transform(result))
                }
            }
        }
    }
}
