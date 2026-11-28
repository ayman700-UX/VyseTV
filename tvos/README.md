# VyseTV for Apple TV

The Apple TV build of VyseTV: the iPhone app's code on a Flutter engine made for tvOS.

**It is a test build.** It is built on GitHub (the `tvos` job, a push whose message has
`[tvos]`; first built 26 November 2026) and has not been run on an Apple TV yet. "What is
proven" at the end says how far each part got.

## Which Apple TVs

Apple TV HD and Apple TV 4K, on tvOS 17 or newer (every Apple TV that had tvOS 15 can update to
17). It was 15 until the party's voice call came in: the WebRTC build it runs on has its Apple TV
slices from tvOS 17.

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

**Updates.** An Apple TV app cannot install a new version of itself. When there is one, the update
box shows a QR code that takes a phone to the release. atvloadly can do it all by itself: it
follows an AltStore source and installs new versions as they come. Each release with an Apple TV
build publishes one (`altstore.json` beside the update list, written by `scripts/make_update.py`);
add its address in atvloadly once and turn on its automatic updates.

## How it works

Flutter's tool has no Apple TV target, so three things are done by hand here.

**The engine.** `tvos/engine.version` and `tvos/engine.sha256` name a Flutter engine built for
tvOS (the same Flutter version as every other build, 3.47.1). `tvos/scripts/fetch_engine.sh`
downloads it, checks the checksum, and writes `tvos/Flutter/Generated.xcconfig`, which tells
Xcode where it is.

**The Dart.** The project's first build phase runs `tvos/scripts/xcode_appletv.sh build`: the
app's assets with `flutter build bundle`, then `lib/main.dart` compiled with `TVOS_BUILD=true`
by that engine's own front end and `gen_snapshot`. Those are for Apple silicon only, and the
build runs on GitHub's Intel Macs (no Apple silicon Mac has ever taken a job of this repository):
there the script uses Flutter's own Dart runtime, front end and iPhone `gen_snapshot` instead,
only when they are the same Dart version as the engine's. The result was checked: the app's
snapshot carries the version hash and features the tvOS engine expects
(`webos-research/tools/snapshot_match.py` on the built `.ipa`). To Dart an Apple TV is an iPhone; that
setting is what tells them apart (`lib/core/platform/apple_tv.dart`, `AppleTv.isTv`).

**The plugins.** No plugin is built for tvOS on its own. The few the app needs are compiled into
the app and registered by hand (`tvos/Runner/AppDelegate.swift`):

| What | From |
|---|---|
| The player (mpv: video, music, audiobooks) | the iPhone's, `ios/Runner/MpvPlayer`, with MPVKit at the iPhone's revision |
| Settings (`shared_preferences`), network state (`connectivity_plus`) | copies of the locked versions, made by `tool/tvos/vendor_plugins.py` |
| Paths, device and app info | ports from upstream (`tvos/Runner/Plugins`) |
| Sign-ins and keys | `KeychainPlugin.swift`: the Keychain, which the system never clears |
| Torrents | `packages/torrserver_flutter`'s plugin, with TorrServer (MatriX.151) linked into the app in the same Go library as the Usenet engine: `packages/vyse_usenet/apple`, built by `packages/vyse_usenet/tool/build_engine.py tvos-arm64` (`[usenet-engine-apple]`) into `vyse-usenet-tvos-arm64.xcframework.zip`. One Go library, never two: two Go runtimes in the app's program crashed 1.0.4 at launch, and the build now fails if it ever holds two (`packages/vyse_usenet/tool/one_go_runtime.sh`). The older `TorrServerKit-tvos.xcframework.zip` (`[tvos-torrent]`) is no longer linked. Device only: there is no simulator build |
| No screen saver during a video | `AppleTvPlugin.swift` |
| A party's voice call | the iPhone's `flutter_webrtc` and `livekit_client`, copied whole at the locked versions by `tool/tvos/vendor_plugins.py` with what tvOS lacks taken out (a phone's loudspeaker switch; the camera and screen capture answer "not on Apple TV"), their Objective-C reaching the Swift through `Runner/Runner-Bridging-Header.h`; WebRTC itself is the build `flutter_webrtc` pins (`tvos/webrtc.version`), its Apple TV slices fetched by `tvos/scripts/fetch_webrtc.sh` and put in the app |

The Dart halves the tool would register from Dart are registered in `AppleTv.install()`.

**The project** (`tvos/Runner.xcodeproj`) is written by `tool/tvos/make_project.py`, which lists
every file. To add one, add it there and run it again. The CI job stops when what is committed is
not what the scripts make.

## What an Apple TV does not have here

- **Downloads.** An app on an Apple TV has no storage the system will not clear when it runs
  short. The Downloads section and the player's Download are not shown.
- **Talking in a party's voice call** needs an iPhone or iPad to lend its microphone: the call
  bar's "Use an iPhone's mic" opens tvOS 17's Continuity picker. Without one the Apple TV is in
  the call listening.
- **Notifications.** A TV app has none; the in-app pop-up is all there is. (Party sounds play,
  through AVAudioPlayer: `AppleTvPlugin.swift`.)
- **Links that open another app or a browser.** There is no browser; the TV's settings QR and the
  phone page are the way to anything that needs one.
- **Updates from inside the app.** It is signed and put on from a computer (see "Updates" above:
  atvloadly does it by itself).

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
| The project, the engine, the Swift | Built on GitHub (26 November 2026): a 45 MB `.ipa`, tvOS 15 and up, arm64, with App.framework (20 MB), the tvOS Flutter engine and the mpv frameworks. The Dart snapshot matches the engine's version hash |
| The voice call | Every copied WebRTC and LiveKit source compiled for tvOS on GitHub (27 November 2026); never run |
| Other player apps | VyseTV hands a link to VLC or Infuse when installed (their x-callback schemes); never run |
| Anything on an Apple TV | Not run yet |

What only an Apple TV can answer, in the order it would show up: does it open; do the remote's
clicks, swipes, Menu and Play/Pause all arrive; does a video play with the picture under the
interface; HDR, Dolby Vision and frame-rate matching; sound passthrough to a receiver; what the
system clears after a week unused.
