import Foundation

/// What the iPhone sends the watch: the library, with small JPEG covers.
struct WatchManifest: Codable {
    let albums: [WatchAlbum]
}

struct WatchAlbum: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artwork: Data?
}

/// What the watch asks the iPhone to do.
enum WatchRequest: Codable {
    case play(albumID: String)
    case sendLibrary
}

/// Wire format for WatchConnectivity message dictionaries.
enum LinkCoding {
    static let payloadKey = "payload"
    /// Present in a reply when the iPhone couldn't carry out the request.
    static let errorKey = "error"
    static let fingerprintKey = "fingerprint"

    struct MalformedMessage: LocalizedError {
        var errorDescription: String? { "Received a message Crate doesn't understand. Update Crate on both devices." }
    }

    static func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        [payloadKey: try JSONEncoder().encode(value)]
    }

    static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any]) throws -> T {
        guard let data = message[payloadKey] as? Data else { throw MalformedMessage() }
        return try JSONDecoder().decode(type, from: data)
    }
}
