import os
import SwiftUI
import WatchConnectivity

/// Sends the library to the watch app and plays the albums the watch picks.
@MainActor
final class WatchSync: NSObject {
    nonisolated private static let sentFingerprintKey = "watchLibraryFingerprint"
    /// Pixel size of the covers sent to the watch.
    private static let thumbnailSide: CGFloat = 160

    private let backend: any MusicBackend
    private let session = WCSession.default
    private let log = Logger(subsystem: Bundle.main.appIdentifier, category: "WatchSync")
    private var isSendingLibrary = false

    init(backend: any MusicBackend) {
        self.backend = backend
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        observeLibrary()
    }

    private func observeLibrary() {
        withObservationTracking {
            _ = backend.albums
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeLibrary()
                await self.sendLibrary(force: false)
            }
        }
    }

    private func handle(_ request: WatchRequest) async throws {
        await backend.load()
        if case .failed(let reason) = backend.state {
            throw PlayerError.libraryUnavailable("Open Crate on your iPhone. \(reason)")
        }
        switch request {
        case .play(let albumID):
            guard let album = backend.albums.first(where: { $0.id == albumID }) else {
                throw PlayerError.albumNotFound
            }
            try await backend.play(album, from: nil)
        case .sendLibrary:
            // Reply right away; building the covers can take a while on big libraries.
            Task { await sendLibrary(force: true) }
        }
    }

    /// Sends the library unless the watch already has this exact version (or `force`).
    private func sendLibrary(force: Bool) async {
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              backend.state == .loaded, !isSendingLibrary
        else { return }
        let albums = backend.albums
        let fingerprint = String(StableHash.djb2(
            albums.map { "\($0.id)|\($0.title)|\($0.artist)" }.joined(separator: "\n")
        ))
        if !force && UserDefaults.standard.string(forKey: Self.sentFingerprintKey) == fingerprint { return }

        isSendingLibrary = true
        defer { isSendingLibrary = false }
        var watchAlbums: [WatchAlbum] = []
        watchAlbums.reserveCapacity(albums.count)
        for (index, album) in albums.enumerated() {
            let artwork = await backend.artwork(for: album, side: Self.thumbnailSide).map(Self.thumbnailJPEG)
            watchAlbums.append(WatchAlbum(id: album.id, title: album.title, artist: album.artist, artwork: artwork))
            if index % 40 == 39 { await Task.yield() }
        }

        let url = URL.cachesDirectory.appending(path: "watch-library-\(UUID().uuidString).json")
        do {
            try JSONEncoder().encode(WatchManifest(albums: watchAlbums)).write(to: url, options: .atomic)
        } catch {
            log.error("Couldn't write the watch library: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Superseded transfers still call didFinish, which deletes their files.
        for transfer in session.outstandingFileTransfers { transfer.cancel() }
        session.transferFile(url, metadata: [LinkCoding.fingerprintKey: fingerprint])
    }

    private static func thumbnailJPEG(_ image: UIImage) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: thumbnailSide, height: thumbnailSide)
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.6) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func removeFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            log.error("Couldn't remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error {
                self.log.error("Watch session failed to activate: \(error.localizedDescription, privacy: .public)")
                return
            }
            await self.sendLibrary(force: false)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The user switched watches; start talking to the new one.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in await self.sendLibrary(force: false) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            do {
                try await self.handle(LinkCoding.decode(WatchRequest.self, from: message))
                replyHandler([:])
            } catch {
                replyHandler([LinkCoding.errorKey: error.localizedDescription])
            }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        let fingerprint = fileTransfer.file.metadata?[LinkCoding.fingerprintKey] as? String
        let errorDescription = error?.localizedDescription
        Task { @MainActor in
            self.removeFile(at: url)
            if let errorDescription {
                self.log.error("Library transfer to watch failed: \(errorDescription, privacy: .public)")
            } else {
                UserDefaults.standard.set(fingerprint, forKey: Self.sentFingerprintKey)
            }
        }
    }
}
