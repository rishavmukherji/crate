import Foundation

extension Bundle {
    /// The app's bundle identifier, which each builder sets through `CRATE_BUNDLE_ID_PREFIX` in Config/Local.xcconfig.
    var appIdentifier: String {
        guard let id = bundleIdentifier else { preconditionFailure("Crate runs as an app bundle") }
        return id
    }
}
