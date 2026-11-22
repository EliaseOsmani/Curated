# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Retune is a SwiftUI iOS app for curating music playlists: pick a playlist, swipe right to keep or left to archive each song, then save the kept songs as a new playlist. Apple Music (MusicKit) is the only live service. There are no third-party dependencies and no backend yet.

`PDR_PlaylistRetuner.pdf` is the product spec and full vision, including a Firebase social layer that does not exist yet. Code comments citing "PDR" refer to it. `Swift_App_Roadmap.pdf` is the developer's learning plan. Treat both as intent, and the code as the truth about what is built.

## Commands

Build for the simulator without signing:

```sh
xcodebuild -project Retune.xcodeproj -scheme Retune -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

There is no test target and no linter or formatter config, so a successful build is the only automated check. Behavior that touches a real Apple Music library needs a device signed in to Apple Music.

`Retune/Secrets.swift` is gitignored but required to compile. A fresh clone must add a `Secrets` type with `static let` strings `spotifyClientID`, `spotifyRedirectURI`, and `spotifyClientSecret`.

## Build configuration

- Deployment target is iOS 26.2. The PDR's "iOS 17" is out of date.
- Swift language mode is 5.0 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. Unannotated code is main-actor isolated, so background work must opt out explicitly.
- The `Retune/` group is a file-system-synchronized group. New files in it join the target automatically, so do not edit `project.pbxproj` to add them.
- Info.plist values are merged from `Retune/Info.plist` and `INFOPLIST_KEY_*` build settings.

## Architecture

**Routing.** `AppStateManager.shared` is the source of truth for auth and routing. `RetuneApp` switches on its `phase` (`launching`, `onboarding`, `home`). Views should read connection state from it rather than checking MusicKit or Keychain directly.

Launch routing deliberately uses local `UserDefaults` flags instead of MusicKit, because Apple's account daemon can be slow or unavailable. Do not add MusicKit auth or account calls to `boot()` or `completeOnboarding()`, and do not call `MusicAuthorization.request()` when status is already determined. The playlist fetch is the authoritative permission check.

**Core flow.**

1. `HomeView` lists playlists from `MusicPlaylistsVM`, wrapped in the cross-service `PlaylistSelection`.
2. `SessionSetupView` loads tracks, maps them to the app's `Song`, and applies the order mode.
3. `RetuneSwipeView` runs the session using `SwipeCard`.
4. `SaveRetunedPlaylistView` allows a final review and writes a new playlist through `SavePlaylistVM`.

**File names do not match their contents:**

- `NavigationStack.swift` holds `RootView`, `HomeView`, `PlaylistSelection`, and the Spotify setup screen and VM.
- `SwipeView.swift` holds `RetuneSwipeView`.
- `RetuneSwipeView.swift` holds `RetuneSessionVM` and `RetuneSessionLoaderView`.
- `RetunedPlaylistsView.swift` holds `RetunePlaylistsView`.

**Session persistence (SwiftData).** `SessionRecord` stores the ordered songs as JSON (`songsJSON`) plus a cascade of `SongDecision`s, written on every swipe. These invariants are easy to break:

- `Song.id` is a new random UUID on every fetch, and decisions reference it. It is stable only inside a record's `songsJSON`. Use `musicItemID` to identify a track across fetches.
- There is one record per `playlistID`. When `RetuneSwipeView` appears with an existing record, it restores from that record and ignores the `songs` and `orderMode` passed in.
- A record is deleted only on full save success or explicit discard. Partial saves keep it so the user can retry.

**Naming.** The app's `Song` shadows `MusicKit.Song`. Always write `MusicKit.Song` for the framework type.

**Spotify is intentionally disabled.** The auth, API, and UI code is complete, but track fetching returns 403 without Spotify Extended Quota Mode, which requires a registered business. Onboarding and Profile show "Coming Soon". `AppStateManager.init` clears Spotify credentials on every launch and `boot()` only routes to Apple Music, so both must change to re-enable it. A `spotify:` prefix on `playlistID` is how the session and save screens detect the platform.

**Unused code.** `PlaylistManager`, `RetunedPlaylist`, `PlaylistViewModel` (hardcoded sample songs), `RetunePlaylistsView`, and `RetuneSessionLoaderView` are not reachable from the running app. The Feed and Notifications tabs are `ComingSoonView` placeholders.
