# VyseTV for Apple TV

The Apple TV build of VyseTV: the iPhone app's code on a Flutter engine made for tvOS.

**It is a test build.** It is built on GitHub (the `tvos` job, a push whose message has
`[tvos]`) and has not been run on an Apple TV yet. "What is proven" at the end says how far
each part got.

## Which Apple TVs

Apple TV HD and Apple TV 4K, on tvOS 15 or newer.

## Putting it on an Apple TV

There is no App Store version. The build is an `.ipa` without a signature
(`VyseTV-tvOS-unsigned.ipa`, from the run's artifact), and it is signed with your own Apple ID
as it is installed:

- **Sideloadly** (Windows or Mac). On the Apple TV: Settings > Remotes and Devices > Remote App
  and Devices, so the computer can pair with it (the Apple TV and the computer on the same
  network). In Sideloadly pick the Apple TV, drop in the `.ipa`, sign in with your Apple ID.
- **atvloadly** (runs in Docker, on a computer or a NAS that stays on) does the same and signs
  it again on its own before it runs out.

With a free Apple ID the signature lasts **7 days**, and three apps at most at a time. With a
paid developer account, a year. After that the app does not open until it is signed again.

## How it works

Flutter's tool has no Apple TV target, so three things are done by hand here.

**The engine.** `tvos/engine.version` and `tvos/engine.sha256` name a Flutter engine built for
tvOS (the same Flutter version as every other build, 3.47.1). `tvos/scripts/fetch_engine.sh`
downloads it, checks the checksum, and writes `tvos/Flutter/Generated.xcconfig`, which tells
Xcode where it is.

**The Dart.** The project's first build phase runs `tvos/scripts/xcode_appletv.sh build`: the
app's assets with `flutter build bundle`, then `lib/main.dart` compiled by that engine's own
front end and `gen_snapshot` with `TVOS_BUILD=true`. To Dart an Apple TV is an iPhone; that
setting is what tells them apart (`lib/core/platform/apple_tv.dart`, `AppleTv.isTv`).

**The plugins.** No plugin is built for tvOS on its own. The few the app needs are compiled into
the app and registered by hand (`tvos/Runner/AppDelegate.swift`):

| What | From |
|---|---|
| The player (mpv: video, music, audiobooks) | the iPhone's, `ios/Runner/MpvPlayer`, with MPVKit at the iPhone's revision |
| Settings (`shared_preferences`), network state (`connectivity_plus`) | copies of the locked versions, made by `tool/tvos/vendor_plugins.py` |
| Paths, device and app info | ports from upstream (`tvos/Runner/Plugins`) |
| Sign-ins and keys | `KeychainPlugin.swift`: the Keychain, which the system never clears |
| The torrent plugin | `packages/torrserver_flutter`; without the engine built for tvOS it answers "no engine", and torrents are hidden |
| No screen saver during a video | `AppleTvPlugin.swift` |

The Dart halves the tool would register from Dart are registered in `AppleTv.install()`.

**The project** (`tvos/Runner.xcodeproj`) is written by `tool/tvos/make_project.py`, which lists
every file. To add one, add it there and run it again. The CI job stops when what is committed is
not what the scripts make.

## What an Apple TV does not have here

- **Downloads.** An app on an Apple TV has no storage the system will not clear when it runs
  short. The Downloads section and the player's Download are not shown.
- **Torrents**, until TorrServer is built for tvOS (the Go shim in `torrserver_flutter`, with a
  gomobile that knows tvOS).
- **Voice calls in a party, party alert tones, notifications.** Their libraries have no tvOS
  side.
- **Links that open another app or a browser.** There is no browser; the TV's settings QR and the
  phone page are the way to anything that needs one.
- **Updates from inside the app.** It is signed and put on from a computer.

What the system may clear: the app's caches (artwork, the scraper plugins' scripts) and its
files. Settings and sign-ins are kept where it does not clear them (the preferences store and the
Keychain).

## The remote

The engine turns the Siri Remote's clicks into arrows and Select, and Menu into Back. Play/Pause
is taken by the app's view controller and sent to Dart; swipes on the touch surface move the
focus one step per stretch of travel (`lib/core/platform/apple_tv_remote.dart`), which is what
the first Siri Remote (no ring) is driven by.

## What is proven

| Part | How far it got |
|---|---|
| The Dart | Analyzed and tested on a PC (`test/apple_tv_remote_test.dart`, `test/tv_secrets_test.dart`) |
| The project, the engine, the Swift | Built on GitHub, when the `tvos` job passes |
| Anything on an Apple TV | Not run yet |

What only an Apple TV can answer, in the order it would show up: does it open; do the remote's
clicks, swipes, Menu and Play/Pause all arrive; does a video play with the picture under the
interface; HDR, Dolby Vision and frame-rate matching; sound passthrough to a receiver; what the
system clears after a week unused.
