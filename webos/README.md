# VyseTV for LG webOS

An LG TV build of VyseTV, made with LG's own Flutter SDK for webOS.

**It is a test build, not a supported platform.** One tester has run it on a webOS 26 set (late
November 2026) and reported that it opened, played video and streamed a torrent. That is one
set, told to us, not seen by us. Two other testers could not start it at all: their TVs are on
an older webOS. For those there is a second package ("Older webOS" below), and nobody has run
that one on a TV yet. Everything here was written from LG's source, from other open-source
players for webOS, and from what could be tested on a PC. "What is proven" below says how far
each part got.

## Which TVs

One build makes two packages. Both are for a TV in Developer Mode.

| Package | For | How far it got |
|---|---|---|
| `com.vyse.vysetv_<version>_arm.ipk` | webOS 26 ("Re:New") and newer | One tester reports it working |
| `com.vyse.vysetv_<version>_arm_older-webos.ipk` | webOS 4 to webOS 25: sets from 2018 on | Never run on a TV |

webOS 3 and older (2017 sets and before) can run neither: too much of what LG's embedder calls
is missing from those TVs' own libraries.

The first package is what LG's tool makes. LG's Flutter engine and the program it is built into
need the C library of webOS 26 (glibc 2.38; webOS 24 and 25 have 2.35, a 2018 set on webOS 4
has 2.24), so it starts on webOS 26 and nowhere else. LG's Re:New programme brings webOS 26 to
2022 and newer OLED and upper QNED sets as updates roll out. The second package is the same
build carrying a C library of its own.

**Which one a TV needs.** On the TV: Settings > General > About this TV (or Support > TV
information), "webOS TV version". On the PC: `ares-device --system-info --device <tv>`; its
`sdkVersion` is 11 or higher on webOS 26 (10 is webOS 25, 9 is 24, 8 is 23, 7 is 22, 6 and 5
are 2021 and 2020 sets, 4 is 2018 and 2019). 11 and up takes the first package, 4 to 10 the
second. Installing one replaces the other.

### The webOS 26 package on an older TV: static, a black screen, or "Not Programmed"

The first package installs on any webOS TV, and on an older one it cannot start: the TV's own
loader refuses the program before a line of the app has run, the app never appears among the
running apps, and the TV goes back to what it was showing, which for a set with no aerial is
static or "Not Programmed". It is not a fault of how it was installed, and installing again
changes nothing. To see the TV say so itself:

```bash
ares-novacom --device <tv> --run "/media/developer/apps/usr/palm/applications/com.vyse.vysetv/vysetv"
```

answers with a line like `version 'GLIBC_2.38' not found`. (The web inspector, `ares-inspect`
and its port 9998, is for web apps. This is a native app and has none, so what it says about
this app means nothing either way.)

What each older webOS lacks, read from the package itself against one real firmware of each
release (webOS Brew's firmware data: every library and function a TV has):

| webOS | Sets from | Beyond the C and C++ runtime, the TV lacks |
|---|---|---|
| 26 | 2022 on, upgraded | nothing |
| 24, 25 | 2022 to 2025 | one function, and it is asked for by this app's own player side (`NDL_MediaInitWithWindowId`) |
| 22, 23 | 2022, 2023 | that, and one function of the Wayland library LG's embedder calls (`wl_proxy_marshal_flags`) |
| 5, 6 | 2020, 2021 | those, and on webOS 5 the call that gives an app more than one player |
| 4 | 2018, 2019 | those, the whole event-loop library LG's embedder runs on (`libsystemd`), and the way the video plane is placed under an app (exported windows): a 2018 or 2019 set would need its video placed another way |

## Older webOS

The second package (`..._older-webos.ipk`) is the webOS 26 build with the following done to it
(`tool/webos/older.sh`, run by `build.sh`). The app itself is the same, file for file.

**A runtime of its own.** A folder `runtime/` holds a loader, glibc 2.41 and the C++ library,
as Debian 13 builds them for 32-bit soft-float ARM, which is the kind of code a webOS TV runs.
They are Debian's files unchanged, four packages, each checked against its checksum as the
package is made (`runtime/README.txt` names them and their source). The app's program is set to
start under that loader and to load that runtime before anything else, and the TV's own
libraries (graphics, Wayland, the media library, Luna) then run on top of it. That is the
direction that works: a library made for an older C library runs on a newer one, never the
other way round. The loader's place is written into the program in full, so this package runs
from where Developer Mode installs apps and nowhere else.

**Stand-ins for what an older TV's own libraries lack** (`packages/vyse_webos/webos/older`).
Each does something only on a TV that lacks the real thing:

| webOS | Sets from | What stands in |
|---|---|---|
| 24, 25 | 2022 to 2025 | Nothing of LG's embedder. The player names its video window in the load request alone, since the call that also names it up front is not there |
| 22, 23 | 2022, 2023 | That, and the call every request to the compositor is sent with (`wl_proxy_marshal_flags`), written with the older calls it replaced |
| 5, 6 | 2020, 2021 | Those, and the version the app's window interface is asked for (below). On webOS 5 the TV gives an app one player where newer sets give several, so the film and the music take turns at it: the one that starts takes it, the other shows as paused and picks up where it was when Play is pressed |
| 4 | 2018, 2019 | Those; the event loop LG's embedder runs on (webOS 4 has no `libsystemd`, so the app brings a loop of its own with the same ten functions); the drawing-window library under the name webOS 4 has it; and the picture is placed by the TV's media library itself, since webOS 4 has no exported windows |

On webOS 4 the last of those shows: the media library can put the whole picture in a
rectangle and no more. Fit, Stretch, the fixed shapes and zooming out work. Fill and zooming in
show as Fit.

*The window interface's version.* LG's embedder asks the compositor for version 2 of
`wl_webos_shell`, the interface a webOS app gets its window through, whatever the compositor
says it has. Version 2 is from the middle of 2020 (the history of webOS's own protocol files,
`webos-wayland-extensions`). A compositor asked for a version it does not have ends the
connection, so on a 2018 to 2020 set the app would be gone before its first picture. In this
package a small library sits between the embedder and the TV's Wayland library
(`older/vyse_wayland.c`): it hears what the compositor offers, and an interface is never asked
for at a higher version than that. Everything the embedder then uses of the interface is in
version 1.

*The media library's window.* Before webOS 26 the TV's media library cannot be handed the
window a video goes in. When a player starts it asks SDL (the library LG's own native apps are
made with) for the app's window and for the id of the window exported from it. This app has no
SDL window, so the library got nothing and the app fell at once on every video and every song
(a webOS 5.6 tester, 27 November 2026: "App closes when playing any media"). The package now
brings a stand-in for SDL (`older/vyse_sdl.c`, under SDL's own name), loaded by the player just
before the first player starts: asked for the window, it answers with the one the app made for
the picture, or a placeholder for sound alone. On such a TV the media library also keeps the
window it started with for good, so one window serves every video of the app's life. An open
project that runs LG's Flutter apps on older webOS found and fixed the same thing on webOS 6.5.

*The Magic Remote.* An older set's compositor offers several input seats (the Magic Remote, a
mouse) without names, and LG's embedder listens to the first seat's pointer only. The remote's
pointer and wheel arrive on another and were dropped. `older/vyse_wayland.c` gives every seat's
pointer the embedder's listener. Pointed with for real (a long move, a click, the wheel), the
pointer then has the app as a mouse has a desktop, and an arrow key hands it back to the
remote's keys (`lib/dpad/input_mode_tracker.dart`).

**Sign-ins and keys.** LG's webOS side of the keychain plugin seals each value with the TV's
key service, which LG's reference gives to apps from webOS 24. On an older set nothing answers
and LG's plugin then keeps nothing, without a word: a debrid key or a tracker sign-in would be
gone as it was saved. The app tries the TV's store once (`lib/core/platform/tv_secrets.dart`,
in both packages), and where it does not keep what it is given, values go to a file in the
app's own folder on the TV instead. That file is not sealed by the TV: this app reads it, and
so can whoever has the TV in Developer Mode, as with everything a web app stores on a TV. If the
TV later gains the service, the file's values move into it.

**A record of the start.** Nobody here has such a TV, so the package writes down how it
started: everything the app, LG's embedder and the loader print goes to
`appdata/vysetv-start.log` in the app's folder, headed by the TV's kernel, its webOS and every
library that was loaded with where each came from. If the app falls in native code, the signal,
the place and the map of what was loaded are added. To read it from the PC:

```bash
ares-novacom --device <tv> --run "cat /media/developer/apps/usr/palm/applications/com.vyse.vysetv/appdata/vysetv-start.log"
```

If there is no such file, the program did not get as far as its first line. Running it by hand
shows why:

```bash
ares-novacom --device <tv> --run "/media/developer/apps/usr/palm/applications/com.vyse.vysetv/vysetv"
```

**What was checked without a TV.**

- Every library the package asks for and every function name its files need, against one real
  firmware of each release (webOS Brew's firmware data): all found on webOS 4.4, 4.10, 5.3,
  6.4, 7.4 (webOS 22), 8.3 (23), 9.2 (24), 10.2 (25) and 11.2 (26). On webOS 3.9 and older they
  are not, which is where the line above comes from.
- A start of the program in an emulator as the package is built: its own loader runs, finds the
  whole runtime in `runtime/` and every library of the package, and stops at the first library
  only a TV has.
- The library between the embedder and the TV's Wayland library, run for real in that
  emulator each time the package is made, on the packaged runtime, against a stand-in for an
  older TV's Wayland library and for a newer one's (`older/test`): version 2 asked of a
  compositor that has 1 goes out as 1, and everything else goes out as it came in.
- LG's embedder itself, read from its machine code: every interface it binds and at which
  version, and the requests it sends on webOS's own interfaces, set against webOS's protocol
  files as they stood in 2018.
  The window interface's version is the one thing a 2018 compositor would refuse. The kernel
  side was checked against the configuration of a real 2021 set (the helpers this runtime
  needs from the kernel are on, and the kernel filters no system calls).
- The player's own side of it (`test/webos_player_test.dart`: a TV with no exported windows,
  a TV with one player, a TV that does not answer what it has), and where sign-ins are kept
  (`test/tv_secrets_test.dart`: a TV's store that works, one that keeps nothing, one that
  refuses, one that never answers, and one that starts working after an update).

**What only a TV can say.** Whether LG's embedder, made for the compositor of webOS 26, gets
along with an older one in what cannot be read from its code. Whether an older set's graphics
driver takes LG's engine. Whether the TV lets a newer C library do all it does inside the app's
sandbox. On webOS 4, whether the
picture lands where it is put. And then everything in "What only a TV can answer" below, which
holds for both packages. The package is also meant to run on webOS 26; that too is untried.

## Building it

LG's SDK builds on Linux only (Ubuntu 22.04, 24.04 or 26.04). It brings its own Flutter
(3.38.10), separate from the Flutter the other platforms are built with; nothing here touches
that one.

On Windows the Linux is WSL2: install "Ubuntu 24.04" from the Microsoft Store (or
`wsl --install -d Ubuntu-24.04` in an administrator's PowerShell), open it, and go to the
repository through `/mnt/c/...`.

Once, on that Linux:

```bash
tool/webos/setup.sh
```

It installs the packages a Flutter Linux build needs, LG's Flutter tool, Node.js 22 with LG's
webOS CLI, and LG's webOS NDK (341 MB). The NDK is under LG's "LG SDK License Agreement": its
installer shows the agreement and asks you. `--accept-lg-ndk-license` answers yes for you; pass
it only if you accept those terms.

Then, for each build:

```bash
tool/webos/build.sh
```

The two packages come out in `build/webos/`: `com.vyse.vysetv_<version>_arm.ipk` and
`com.vyse.vysetv_<version>_arm_older-webos.ipk`.

Without a Linux machine: a push to GitHub whose message has `[webos]` builds the same two
there (the `webos` job in `.github/workflows/build.yml`) and keeps them as the run's artifact
for two days. That job runs only once the repository variable `LG_NDK_LICENSE` is set to
`accepted`, which is the repository's owner accepting LG's agreement.

The build needs `lib/data/server_config.dart`, as every platform's does (it is not in the
repository: copy `lib/data/server_config.example.dart` and fill it in).

### Checking the Dart side on any PC

Most of what can break the webOS build is Dart: LG's Flutter is older than the project's, and a
line of newer syntax or a newer package anywhere in `lib/` stops it. That can be checked
without Linux and without LG's tools, with a stock Flutter 3.38.10 beside the project's own:

```bash
git clone -b 3.38.10 --depth 1 https://github.com/flutter/flutter.git <somewhere>/flutter-3.38.10
python tool/webos/check.py --flutter <somewhere>/flutter-3.38.10
```

It resolves the webOS copy's packages, analyzes `lib/`, and compiles the whole program the way
LG's tool does. It cannot make the package: the TV's code has to come from LG's own compiler,
which runs on Linux.

## Putting it on a TV

1. On the TV, install **Developer Mode** from the LG Content Store, sign in with an LG developer
   account (free), turn Dev Mode on and let the TV restart. Turn **Key Server** on in that app.
2. On the PC (LG's webOS CLI; `setup.sh` installed it on the Linux side, and it also runs on
   Windows):

   ```bash
   npm install -g @webos-tools/cli@3.2.6   # on Windows too; needs Node.js 20 or newer
   ares-setup-device          # add the TV: its address, port 9922, user "prisoner"
   ares-novacom --device <tv> --getkey   # asks for the passphrase the Developer Mode app shows
   ares-install --device <tv> build/webos/com.vyse.vysetv_<version>_arm.ipk
   ```

   (on a TV older than webOS 26, the `..._older-webos.ipk` one: see "Which TVs"), or build and
   install in one go: `tool/webos/build.sh --install <tv>`, which asks the TV which webOS it is
   and picks the package.

Developer Mode lasts 1000 hours and is extended from its app on the TV; when it runs out, the
TV removes what was installed with it. One TV per developer account at a time.

The app's own log is in its folder on the TV (`appdata/log`). The TV's player reports its
faults to the app, and they are shown: on screen when a video will not play,
and on the report card in the player's Settings menu (Stream info), which also has the TV's
model and webOS version. A photo of that card is the most useful thing to send back.

## How it works there

A webOS TV says it is Linux, so the app is told apart by a build setting (`VYSE_WEBOS`, read in
`lib/core/platform/webos.dart`). With it on, the app is a TV app: the remote drives it through
the same D-pad kit as an Android TV (`lib/dpad`), the interface is drawn the lean way
(`lib/core/lean.dart`), and everything that belongs to a desktop is off.

**The player** is the TV's own (`lib/mpv/player/platform/player_webos.dart`, a third engine
beside mpv and Media3). The app hands the TV an address; the TV fetches, decodes in hardware
and shows the picture on its video plane, under the app's interface. That is the way LG's own
Flutter video plugin plays, and it is where the TV's whole picture chain is: 4K, HDR10, HLG,
Dolby Vision, and Dolby sound decoded or passed to a receiver as the TV's sound settings say.
The native side is small (`packages/vyse_webos`: it passes calls to LG's NDL media library and
events back); everything that decides anything is Dart, and tested.

- *Where the picture sits.* The app's window is see-through where the video shows, and the
  video plane is placed through LG's embedder. The TV stretches the plane to whatever rectangle
  it is given, so black bars, Fill, Stretch, the fixed shapes and Zoom are all worked out in the
  app.
- *Headers.* The TV cannot be given a link's HTTP headers. A link that needs some is opened
  through a small relay on the TV itself (`lib/mpv/support/header_relay.dart`). Playlists
  already went through the app's own relay.
- *Subtitles.* A subtitle file is read by the app and drawn by the app
  (`lib/screens/player/caption_overlay.dart`), in the whole look from Settings. A track inside
  the video file is switched on in the TV's player.
- *Sound.* The remote's volume is the TV's. Audio sync, the channel limit, levelling and
  Passthrough are not offered: the TV's player has none of them, and its own sound settings
  decide what reaches a receiver.
- *Not there:* upscaling and ambient lighting (mpv shaders), subtitle sync by ear (it needs a
  second decoder), picture-in-picture, external players (no other player app on an LG TV takes
  a link), Downloads (on no TV).

**A party's voice call**, listening: there is no WebRTC library for an LG TV's 32-bit ARM, and
LG gives apps no microphone. So the TV joins the call through VyseTV's own small LiveKit client,
`packages/vyse_webos/voice` (Go: LiveKit's Go SDK receives everyone's audio, libopus decodes it,
the voices are mixed with each person's volume and played through ALSA, or PulseAudio when ALSA
does not open). `tool/webos/build.sh` builds it with LG's NDK before LG's tool runs; the plugin's
CMake puts it in `lib/`. The party's sounds (join, leave, a message) play through the same
output. Never run on a TV: whether a webOS app may open ALSA or PulseAudio is the first thing a
TV will say.

**Torrents** play through the same engine as on a PC: TorrServer's own 32-bit ARM build, a
static program carried in the package (`packages/torrserver_flutter/webos`) and started by the
app. On a TV it listens on the TV only, with less memory and fewer connections by default.

**Scraper plugins** run in QuickJS, built for the TV from its author's source as part of the
package (`packages/vyse_webos/webos/CMakeLists.txt`).

**The Back key.** On webOS the TV keeps Back for itself unless the app's window asks for it
(`_WEBOS_ACCESS_POLICY_KEYS_BACK`). The app asks, natively as it starts and once more when the
first page is up. LG's embedder then hands Back to Flutter as Escape, which every page already
listens for.

## What is proven, and what is not

| Part | How far it got |
|---|---|
| The app's Dart code on LG's Flutter (3.38.10, Dart 3.10) | Compiles whole, as LG's tool compiles it, on a PC (`tool/webos/check.py`) |
| The player's logic: opening, events, seeking, tracks, subtitles, picture shape, faults, the decoder being taken by another app | Tested on a PC, against a stand-in that sends the TV's events as LG's plugin reads them |
| The player page, Settings and the phone page in TV mode | Tested on a PC (`test/dpad/t4_journeys_webos_test.dart`) |
| The player's native side (C++) | Built with LG's NDK, against the TV's real media library, with LG's own warning settings. It asks the TV for `libNDL_media.so.1` and `libglib-2.0.so.0`. Never run |
| The JavaScript engine for plugins | Built with LG's NDK, every function the app needs present. Never run on a TV |
| The package for webOS 26 (.ipk) | Built by `tool/webos/build.sh` on GitHub (26 November 2026): 55 MB, 32-bit ARM, the app's code stamped for LG's engine, the torrent engine marked as a program. One tester reports it opening, playing video and streaming a torrent on a webOS 26 set |
| The package for older webOS | Built the same way, the same day. Checked by name against one firmware of each release from webOS 4.4 on, and started in an emulator as far as the first library only a TV has ("Older webOS" above). A webOS 5.6 tester (27 November): it starts, the menus, search, the manga reader and signing in work; every video and song closed the app (the media library's window, fixed since, not yet tried there); the Magic Remote's pointer did nothing (fixed since, not yet tried there) |
| Anything else on a TV | Not reported yet: Back, HDR and Dolby Vision, sound formats, music, plugins |

What only a TV can answer, in the order it would show up:

1. **Does it start.** The engine, LG's embedder and the plugins loading on the set.
2. **Does Back reach the app.** LG wrote in October 2026 that their Flutter SDK did not yet let
   an app take the Back key (the TV showed its own "exit the app?" box). The window property
   above is how every other native app takes it, and LG's newer embedder has more for it
   (`setKeyMask` on its `webos/system` channel). If Back still does not arrive, that call is the
   next thing to try, then a second key standing in for Back.
3. **Does a video play, and where does the picture land.** The plane's rectangle is given in
   the interface's own pixels, as LG's plugin gives it; whether a 4K panel wants anything else
   is not written down.
4. **Does the TV's player reach addresses on the TV itself** (`127.0.0.1`). Playlists, torrents
   and links with headers all depend on it.
5. **Does the torrent engine start** inside the app's sandbox on webOS 26, and resolve names
   (it brings its own resolver).
6. **HDR and Dolby Vision.** The TV decides by itself from the stream. The report card shows
   what its player said it is showing. Dolby Vision inside MKV is played from webOS 25 on.
   The interface over an HDR picture may look too bright.
7. **Sound formats.** TrueHD is never played by the TV's player, DTS depends on the set's year.
   Such a track gives the fault "The TV can't play this sound", and another track or source is
   the way out. A second engine that feeds the TV's decoders itself (as mpv and Kodi do on
   webOS) is what would lift that, along with picture subtitles (PGS) and styled ones (ASS).
8. **Music.** Whether the TV's player takes the audio streams music comes as.
