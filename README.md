# DRIFT — iOS

A native rebuild of the particle game from [phronesis.world/drift](https://phronesis.world/drift).
Not a wrapper around the web version — a second implementation of the same game, against
the same multiplayer server.

## Why the rewrite, when the shell worked

The WKWebView shell is still here (`App.swift`, `web/`) and it did its job: the game was
bundled and loaded from `file://`, so it ran with the radio off. But guideline 4.2 does not
ask whether the packaging is good, it asks whether the app does something its website
cannot — and a bundled canvas answers no however well it is wrapped.

The native build answers it four times, and each is a real capability rather than a
checkbox:

| | why the web cannot |
|---|---|
| **Game Center** | system identity, friends' scores, achievements that outlive the app |
| **CoreHaptics** | iOS Safari does not implement `navigator.vibrate` — the web game's haptics are silently dead on every iPhone |
| **SwiftUI menus** | canvas rectangles have no VoiceOver, no Dynamic Type, no keyboard or switch control |
| **Native lobby** | pull-to-refresh, system keyboard, real list semantics |

## Layout

```
Native/
  DriftCore.swift      the simulation — imports NO rendering framework
  DriftScene.swift     SpriteKit renderer + input
  Haptics.swift        CoreHaptics, with a UIImpactFeedback fallback
  DriftApp.swift       SwiftUI shell: menu, class select, game, game over
  ServerBrowser.swift  the native lobby
GameCenter.swift       leaderboards, achievements, dashboard
```

`DriftCore` imports no rendering framework deliberately. It runs in a plain `swiftc` binary
with no simulator, so the physics can be tested and checked against the web version's
numbers. The web game mixes simulation and drawing in one 1490-line file, which is exactly
why none of it can be tested; keeping that seam is the main thing the rewrite buys.

## The one number that must not drift

The multiplayer field is generated from `(seed, tick)` on every client, so a native player
and a browser player have to compute an identical field. `Mulberry` mirrors `mulberry32`
from `mp.js` and the Durable Object bit-for-bit:

```
Swift  mulberry(42): 0.601103752  0.448290559  0.852465793
JS     mulberry(42): 0.601103752  0.448290559  0.852465793
```

Checked, not assumed. The first version divided by `UInt32.max` rather than 2³², putting
every value a hair high — the two fields would have diverged slowly and invisibly, and
nobody would have known until two players compared screens.

## State

**Done:** simulation core, SpriteKit renderer, haptics, menu, class select, game over,
Game Center, native server browser. Typechecks against the iOS SDK.

**Still to port:** gates, the four class abilities, the seven modes, and the multiplayer
session — the lobby lists servers and joins, but the WebSocket is not yet wired to the
native scene. The web build stays canonical and fully playable throughout.

## Build

```
swiftc -typecheck -sdk $(xcrun --sdk iphonesimulator --show-sdk-path) \
  -target arm64-apple-ios17.0-simulator Native/*.swift GameCenter.swift
```

## Before it can be submitted

- no `.xcodeproj` — this builds with `swiftc` and a hand-written `Info.plist`, which cannot
  archive for distribution
- no app icon or launch screen
- unsigned; needs a device build under the team
- leaderboard and achievement ids in `GameCenter.swift` must be created in App Store
  Connect and match exactly. A typo there fails silently at submit time, which is the worst
  way for it to break.
