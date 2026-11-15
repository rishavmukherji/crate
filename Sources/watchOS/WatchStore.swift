import SwiftUI
import WatchConnectivity
import WatchKit

/// The library synced from the iPhone, and the link used to ask the iPhone to play.
@Observable
@MainActor
final class WatchStore: NSObject {
    enum SyncState: Equatable {
        case idle
        case requesting
        case waitingForTransfer
    }

    private(set) var albums: [WatchAlbum] = []
    private(set) var syncState: SyncState = .idle
    var errorMessage: String?

    @ObservationIgnored private let imageCache = NSCache<NSString, UIImage>()

    nonisolated private static var manifestURL: URL {
        URL.documentsDirectory.appending(path: "library.json")
    }

    override init() {
        super.init()
        loadStoredManifest()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func image(for album: WatchAlbum) -> UIImage? {
        let key = album.id as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let data = album.artwork, let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    func play(_ album: WatchAlbum) {
        WKInterfaceDevice.current().play(.click)
        send(.play(albumID: album.id)) {}
    }

    func requestLibrary() {
        syncState = .requesting
        send(.sendLibrary) { [weak self] in self?.syncState = .waitingForTransfer }
    }

    private func send(_ request: WatchRequest, onSuccess: @escaping @MainActor () -> Void) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            return fail("Still connecting to your iPhone. Try again in a moment.")
        }
        guard session.isReachable else {
            return fail("Can't reach your iPhone. Make sure it's nearby with Bluetooth on.")
        }
        let message: [String: Any]
        do {
            message = try LinkCoding.encode(request)
        } catch {
            return fail(error.localizedDescription)
        }
        session.sendMessage(message, replyHandler: { reply in
            let error = reply[LinkCoding.errorKey] as? String
            Task { @MainActor in
                if let error { self.fail(error) } else { onSuccess() }
            }
        }, errorHandler: { error in
            Task { @MainActor in self.fail(error.localizedDescription) }
        })
    }

    private func fail(_ message: String) {
        errorMessage = message
        syncState = .idle
        WKInterfaceDevice.current().play(.failure)
    }

    private func loadStoredManifest() {
        let url = Self.manifestURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            albums = try JSONDecoder().decode(WatchManifest.self, from: Data(contentsOf: url)).albums
            imageCache.removeAllObjects()
            syncState = .idle
        } catch {
            fail("Your synced library couldn't be read. Sync it again from your iPhone. (\(error.localizedDescription))")
        }
    }

    private func requestLibraryIfMissing() {
        guard albums.isEmpty, syncState == .idle, WCSession.default.isReachable else { return }
        requestLibrary()
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let errorDescription = error?.localizedDescription
        Task { @MainActor in
            if let errorDescription { return self.fail(errorDescription) }
            self.requestLibraryIfMissing()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.requestLibraryIfMissing() }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The received file is deleted when this method returns, so move it synchronously.
        let destination = Self.manifestURL
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: file.fileURL)
            } else {
                try FileManager.default.moveItem(at: file.fileURL, to: destination)
            }
            Task { @MainActor in self.loadStoredManifest() }
        } catch {
            let description = error.localizedDescription
            Task { @MainActor in self.fail("Couldn't save your library: \(description)") }
        }
    }
}
