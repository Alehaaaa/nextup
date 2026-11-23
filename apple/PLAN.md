# Nextup for Apple platforms: native Swift rebuild

This folder holds a native rewrite of Nextup for **iPhone, iPad and Mac**, written in Swift with
SwiftUI. One codebase, one set of screens, adapted per device the way native Apple apps are
("fits each screen": touch on iPhone/iPad, windows, sidebar, menus and keyboard shortcuts on Mac).

The Flutter app on `main` stays the reference for behaviour. Nothing in this folder touches it.

## Why it is phased

The Flutter app is about 1,080 Dart files and 670k lines. A faithful native port is many weeks of
work, so it is built in vertical slices. Each phase ends with an app that builds and runs on both
platforms and does something useful end to end.

## Layout

```
apple/
  project.yml                 XcodeGen spec: iOS and macOS app targets sharing one source tree (iOS 26+, macOS 26+)
  App/                        SwiftUI app (shared by iOS and macOS)
    Shell/                    App entry, tab bar (iPhone) / sidebar (iPad, Mac), routing, deep links
    Home/ Search/ Detail/     Discovery screens
    Player/                   Playback (AVKit today, engine behind a protocol)
    Library/                  Continue Watching, watchlist, downloads
    Settings/                 Accounts, addons, playback, looks
    Components/               Poster cards, rails, glass surfaces, theme
  Packages/NextupKit/         Platform-free Swift package: models, API clients, persistence
    Core/                     HTTP client, keychain, settings store
    Metadata/                 TMDB
    Addons/                   Stremio addon protocol (manifest, catalogs, meta, streams)
    Debrid/                   Real-Debrid, TorBox (AllDebrid, Premiumize, PikPak later)
    Tracking/                 Trakt (device code), Simkl, MDBList later
    Library/                  Continue Watching / progress store
```

Generate the Xcode project with `brew install xcodegen && cd apple && xcodegen`, then open
`Nextup.xcodeproj`. CI does the same (`.github/workflows/apple.yml`).

## Phases

| Phase | Scope | Status |
|---|---|---|
| 0 | Project scaffold, theme, navigation shell for iPhone/iPad/Mac, CI build for both | **in this branch** |
| 1 | TMDB home rows + search + title detail (seasons/episodes), Stremio addons (install by URL, streams), Real-Debrid + TorBox resolve, AVKit player with resume, Trakt sign-in, Continue Watching (local) | **in this branch** |
| 2 | Better player engine for MKV/HEVC/subtitles (MPVKit or VLCKit), external subtitles (OpenSubtitles addon), audio/subtitle track menus, Now Playing / lock screen, PiP | next |
| 3 | Trakt/Simkl/MDBList sync: scrobble, history, watchlists, Continue Watching merge (furthest point wins), calendar, `debrify://episode` deep links | |
| 4 | Downloads: background `URLSession` downloads, season/series scopes, offline library, auto-download filters | |
| 5 | Cloud browsing: provider file trees, AllDebrid / Premiumize / PikPak, WebDAV, media servers (Plex/Jellyfin/Emby) | |
| 6 | IPTV (M3U/Xtream/XMLTV EPG) as a **Live** tab with a now/next guide, Reels, collections, stream badges, filters/Quick Play rules | |
| 6b | Home branches editor (Cedar's "Edit Branch"): choose content (catalog, list, favorites; movies/shows/both) and style (Classic, Critic, Gallery, Landscape, Feature), reorder and hide rows | |
| 7 | Backup/restore compatible with the Flutter app's export format, WebDAV saved syncs, profiles | |
| 8 | Polish: Looks (structure + palette), Mac menus/commands, iPad multitasking, accessibility, localisation, release workflow (IPA + SideStore source, DMG) | |

## Look and feel

Reference: Cedar (cedartv.github.io/cedar-tv-updates), native Liquid Glass.

- **Native only.** System controls, materials and colours throughout: `.glass` / `.glassProminent`
  button styles, `GlassEffectContainer`, menus, pickers, forms, alerts, `ContentUnavailableView`,
  the system tab bar / sidebar / toolbar tabs, and the system player (`AVPlayerViewController`
  presented full screen on iPhone/iPad, `AVPlayerView` in a window on Mac) with its own PiP,
  AirPlay and track menus. No hand-made glass, shadows or custom colours; the only brand touch is
  the accent colour in the asset catalog.
- Home: a full-bleed paging hero under the glass chrome (`backgroundExtensionEffect`) with a
  centered title, facts and a More chip; then rows ("branches") whose header opens the full list,
  in poster, wide (landscape) and Top 10 styles.
- Title page: full-bleed artwork, centered title/facts/synopsis, a white Resume capsule with round
  glass Random / Favorite / Watchlist buttons (capsules with labels on Mac), a Season menu and an
  episode rail on every device. A ⋯ menu holds Share, IMDb and Trailer.
- Tabs: floating glass tab bar on iPhone (Home, Library, Search), toolbar tabs on the Mac.
  Settings sits behind a glass gear button (the Settings window on the Mac).
- Search opens on trending rows and a ranked "What Should I Watch" list before you type.
- System chrome only: adaptable `TabView` (floating glass tab bar on iPhone, sidebar on iPad/Mac),
  search tab role, glass / glassProminent buttons, `GlassEffectContainer` for grouped controls.
- Requires iOS 26 / macOS 26 (Liquid Glass APIs). CI builds with the newest Xcode on the runner,
  so newer SDK styling (iOS 27) is picked up automatically.

## Cross-platform rules

- Every screen is one SwiftUI view used on both platforms. `#if os(...)` is allowed only for
  platform glue (window commands, haptics, `UIApplication`/`NSWorkspace`), never for a
  different layout of the same feature.
- Navigation: one `TabView` with `.sidebarAdaptable`. Same sections in the same order everywhere.
- Business logic lives in `NextupKit` and never imports SwiftUI/UIKit/AppKit, so it can be unit
  tested with `swift test` and reused for a future tvOS target.
- Secrets (debrid keys, tracker tokens) go in the Keychain; plain preferences in `UserDefaults`.

## Known gaps and things not verified

- **No device testing.** Development happens without Xcode or a simulator; the CI workflow
  compiles both platforms on a macOS runner, which is the only automated check.
- **AVKit cannot play MKV** and many HEVC/DTS/TrueHD streams that debrid services return. Phase 2
  replaces the engine; until then such streams show a clear "this format needs the next player"
  error and an "Open in VLC / Infuse" action.
- TMDB needs a read access token, supplied at build time through `TMDB_READ_ACCESS_TOKEN`
  (Info.plist key `NXTMDBToken`) or pasted in Settings.
- Feature parity with `main` is the goal of the whole plan, not of phase 1.

## Parity checklist (everything in the Flutter app)

Status: ✅ in the native app · 🟡 partial · ⬜ not started. Android TV / tvOS-only parts are out of scope for iOS/macOS.

**Discovery**
- ✅ Home hero + rows, See All · 🟡 row styles (poster/wide/Top 10) · ⬜ branches editor (choose content + style, reorder, hide rows), Home page settings
- ⬜ Collections (imported folder groups as Home rows) · ⬜ Discover page (metadata explore, filters, genres, layouts) · ⬜ Calendar (Trakt/airing)
- ✅ Search (TMDB + addon catalogs, trending, ranked picks) · ⬜ keyword/torrent search, indexer managers (Prowlarr/Jackett), scraper engines
- ✅ Title page · ⬜ cast/person pages, OMDb ratings, IMDb credits, parents guide, offline copy of title pages
- 🟡 Reels (TMDB clips via Cobalt) · ⬜ direct YouTube extraction fallback, HD adaptive

**Sources & playback**
- ✅ Stremio addons (install, order, enable) · ⬜ addon hub / marketplace, addon auto-update, stream badges, saved source filters, Quick Play rules, source intent everywhere
- 🟡 Debrid: ✅ Real-Debrid, TorBox · ⬜ AllDebrid, Premiumize, PikPak · ⬜ cloud file browsers per provider, torrent management, bulk add, magnet links
- ✅ System player (PiP, AirPlay, track menus) · ⬜ MKV/HEVC/DTS engine (MPVKit/VLCKit), external subtitles, subtitle styling/priority, next-episode autoplay, play loader screen, external players settings
- ⬜ Now Playing / lock screen metadata, media keys

**Library & tracking**
- 🟡 Continue Watching (local) · ⬜ merged across Trakt/Simkl/MDBList (furthest point wins), hide watched
- 🟡 Trakt (sign-in, scrobble, paused, watchlist) · ⬜ history sync, lists, calendar, ratings · ⬜ Simkl · ⬜ MDBList
- ✅ Favorites, Watchlist (device) · ⬜ synced with trackers
- ⬜ `debrify://episode` / `nextup://` deep links (Up Next for Trakt)

**Downloads**
- 🟡 Background downloads, offline library, season download · ⬜ series scope, auto-download with saved filters (codec etc.), download settings, storage usage, posters with radial progress, offline artwork cache

**Live & other sources**
- ⬜ IPTV: M3U, Xtream Codes, XMLTV EPG, guide grid, categories/order/hidden, recordings, Stremio-as-IPTV
- ⬜ Debrify TV (keyword channels), Stremio TV (random-play channels), community channels
- ⬜ Media servers (Plex/Jellyfin/Emby) · ⬜ WebDAV browsing · ⬜ YouTube, Reddit, Lemmy video sources

**Account & app**
- 🟡 Settings (accounts, addons, Trakt) · ⬜ settings search, playback, metadata, looks/palettes, sidebar customisation
- ⬜ Profiles · ⬜ Backup/restore (compatible with the Flutter export) · ⬜ WebDAV saved syncs with snapshots · ⬜ device-to-device transfer (LAN)
- ⬜ Onboarding / initial setup · ⬜ in-app update check (native releases) · ⬜ launch animation · ⬜ localisation, accessibility pass
