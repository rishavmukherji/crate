import Foundation
import os

/// Cover art from the Music app. The library database (iTunesLibrary) has no artwork for songs
/// streamed from Apple Music, but the Music app hands it out over Apple Events.
///
/// Requests for the same track share one fetch. The newest request is served first (the covers
/// that just scrolled into view), a request is dropped once everyone waiting on it is cancelled,
/// and fetched art is cached on disk so it is only fetched once.
@MainActor
final class MusicAppArtwork {
    private let scripting: MusicAppScripting
    private let directory: URL
    private let log = Logger(subsystem: Bundle.main.appIdentifier, category: "artwork")
    /// Called with the first fetch error, so a broken setup (e.g. no permission to control Music) is visible.
    var onFirstError: ((Error) -> Void)?

    private typealias Location = MusicAppScripting.TrackLocation
    private var waiters: [Location: [UUID: CheckedContinuation<Data?, Never>]] = [:]
    /// Tracks waiting to be fetched, oldest first.
    private var queue: [Location] = []
    private var inFlight: Location?
    private var isWorking = false
    private var noArtwork: Set<Location> = []
    private var reportedError = false

    init(scripting: MusicAppScripting) {
        self.scripting = scripting
        directory = URL.cachesDirectory.appending(path: "\(Bundle.main.appIdentifier)/Artwork", directoryHint: .isDirectory)
    }

    /// The encoded artwork image of a track, or nil when it has none (or the request was cancelled).
    func imageData(for track: MusicAppScripting.TrackLocation) async -> Data? {
        if noArtwork.contains(track) { return nil }
        if let cached = await readCache(trackID: track.trackID) { return cached }
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                waiters[track, default: [:]][requestID] = continuation
                if inFlight != track {
                    queue.removeAll { $0 == track }
                    queue.append(track)
                }
                Task { await work() }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(track, requestID: requestID) }
        }
    }

    private func cancel(_ track: Location, requestID: UUID) {
        waiters[track]?.removeValue(forKey: requestID)?.resume(returning: nil)
        if waiters[track]?.isEmpty == true {
            waiters[track] = nil
            queue.removeAll { $0 == track }
        }
    }

    private func work() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        while let track = queue.popLast() {
            inFlight = track
            let data: Data?
            do {
                data = try await scripting.artworkData(track)
                if let data { await writeCache(data, trackID: track.trackID) } else { noArtwork.insert(track) }
            } catch {
                data = nil
                log.error("Artwork fetch failed for \(track.trackID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if !reportedError {
                    reportedError = true
                    onFirstError?(error)
                }
            }
            inFlight = nil
            for continuation in (waiters.removeValue(forKey: track) ?? [:]).values {
                continuation.resume(returning: data)
            }
        }
    }

    private func cacheURL(trackID: String) -> URL {
        directory.appending(path: "\(trackID).img")
    }

    private func readCache(trackID: String) async -> Data? {
        let url = cacheURL(trackID: trackID)
        let log = log
        return await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                return try Data(contentsOf: url)
            } catch {
                log.error("Couldn't read cached artwork: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    private func writeCache(_ data: Data, trackID: String) async {
        let url = cacheURL(trackID: trackID)
        let directory = directory
        let log = log
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("Couldn't cache artwork: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }
}
