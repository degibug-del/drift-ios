# DRIFT — iOS

The particle game from [phronesis.world/drift](https://phronesis.world/drift), as a native
app. Steer one line through a particle field. One run.

    ./build.sh --run          # builds and launches on the simulator

## Bundled, not fetched

`web/` ships inside the app and `WKWebView` loads it from `file://`. There is no network
in the play path — it works on a plane, in a tunnel, with the radio off.

That is also what App Store guideline 4.2 turns on: a WKWebView pointing at a URL is a
browser and gets rejected. What makes this an app rather than a wrapper:

- **bundled offline** — the service worker is dropped, because the bundle *is* the offline story
- **haptics** — `window.webkit.messageHandlers.haptic` bridged to `UIImpactFeedbackGenerator`
- **idle timer held off** — the screen cannot dim mid-run
- **absolute paths rewritten** — `/drift/...` resolves against a web origin, not a bundle;
  left alone the icons 404 silently and the game boots without them
- **the "back to phronesis.world" link removed** — it would exit the app entirely, which
  is precisely what makes something read as a browser
- **TAP, not SPACE** — the copy said `SPACE to activate` on a device with no keyboard.
  Verified before changing it: `touchstart` is bound to the same `fireAbility()` the
  spacebar calls, so the new wording describes something that actually happens. The web
  build keeps SPACE, because there it is true.

## Not yet ready to submit

- no app icon or launch screen
- no `.xcodeproj` — this builds with `swiftc` and a hand-written `Info.plist`, which
  cannot archive for distribution
- unsigned; needs a device build under a real team
- the build emits `using sysroot for 'MacOSX' but targeting 'iPhone'` — runs correctly on
  the simulator, but the sysroot comes from the host rather than the iOS SDK
