# Crate

Browse your music library as a Cover Flow wall of album covers, on Mac, iPhone and Apple Watch.
Switch between **Albums** and **Playlists** (Favorite Songs comes first). Opening a playlist shows a
Cover Flow of the albums its songs come from; flip one to see its songs from that playlist and play the
playlist from there.

| Platform | Library | Playback |
| --- | --- | --- |
| iPhone | MediaPlayer (`MPMediaQuery`) | System Music player: keeps playing in the background, shows in Control Center |
| Mac | iTunesLibrary (the Music app's library); covers of streamed songs come from the Music app | Apple Events to the Music app, one track at a time, advanced by Crate |
| Apple Watch | Synced from the iPhone (covers sent as small JPEGs) | Asks the iPhone to play; Now Playing page controls it |

Tap the centered cover to flip it over to its tracklist (iPhone/Mac); tap a song to play from there, or tap outside the cover to flip it back. On the watch, turn the Digital Crown to flip through albums and tap the center cover to play it on your iPhone.

Mac keys: ← → move, Return flips the cover, Space plays/pauses, trackpad swipes scroll.

## Build

You need a Mac with Xcode (with the iOS and watchOS platforms: Xcode › Settings › Components),
[XcodeGen](https://github.com/yonaskolb/XcodeGen), and an Apple Account added to Xcode (Xcode › Settings › Accounts).
A free account works.

1. Set up signing with your own team and app IDs:

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

   Then edit `Config/Local.xcconfig`: set `DEVELOPMENT_TEAM` to your team ID and `CRATE_BUNDLE_ID_PREFIX`
   to a prefix you own, like `com.yourname`. Git ignores this file.

2. Generate the Xcode project from `project.yml` and open it:

   ```bash
   brew install xcodegen   # once
   xcodegen generate
   open Crate.xcodeproj
   ```

   Run `xcodegen generate` again whenever `project.yml` or `Config/Local.xcconfig` changes.

3. Run it:
   - **iPhone + Watch:** turn on Developer Mode on both (Settings › Privacy & Security › Developer Mode). Select the
     `Crate` scheme and your iPhone, then Run. The watch app is embedded and installs on the paired watch. If the
     iPhone won't open the app, trust your developer certificate in Settings › General › VPN & Device Management.
     Allow access to Apple Music when asked.
   - **Mac:** select the `CrateMac` scheme, then Run. Allow access to Apple Music, and allow Crate to control the
     Music app (needed for playback and for the covers of streamed songs, which are cached in Crate's folder in
     `~/Library/Caches`).
   - **iOS Simulator:** there is no music library in the Simulator, so it runs on a built-in demo library.

With a free account, apps installed on iPhone and Watch stop opening after 7 days; run them from Xcode again to
renew. A free account can also have only 3 of its apps installed on a device at once.

The app icon is drawn by `Tools/make_icon.py` (needs Pillow): edit it and run `python3 Tools/make_icon.py` to regenerate every size.

## Notes

- Requires iOS 17, macOS 14, watchOS 10 (every Apple Watch SE generation can run watchOS 10).
- No MusicKit: it needs a paid developer membership. The libraries above work with a free account, but only see music that's in your library (added or synced), not the Apple Music catalog.
- The watch shows albums only, not playlists.
- Playing an album on iPhone turns shuffle off in the Music app so the album plays in order.

## License

MIT. See [LICENSE](LICENSE).
