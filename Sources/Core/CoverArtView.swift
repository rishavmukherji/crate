import SwiftUI

/// Album artwork, or a generated cover when the library has no artwork for the album.
struct CoverArtView: View {
    let image: PlatformImage?
    let title: String
    let artist: String
    let seed: String

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                PlaceholderCover(title: title, artist: artist, seed: seed)
            }
        }
        .clipped()
    }
}

struct PlaceholderCover: View {
    let title: String
    let artist: String
    let seed: String

    var body: some View {
        let hue = Double(StableHash.djb2(seed) % 360) / 360
        GeometryReader { geo in
            let side = max(geo.size.width, 1)
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.85),
                    Color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.3),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: side * 0.02) {
                    Text(title).font(.system(size: side * 0.1, weight: .heavy))
                    Text(artist).font(.system(size: side * 0.07, weight: .medium)).opacity(0.8)
                }
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(side * 0.07)
            }
        }
    }
}
