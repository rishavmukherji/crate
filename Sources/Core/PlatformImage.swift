import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}
#else
import AppKit
typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}
#endif

enum StableHash {
    /// Deterministic across launches, unlike `hashValue`.
    static func djb2(_ string: String) -> UInt64 {
        string.utf8.reduce(5381) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
    }
}
