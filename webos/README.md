# VyseTV for LG webOS

An LG TV build of VyseTV, made with LG's own Flutter SDK for webOS.

**It is a test build, not a supported platform.** One tester has run it (late November 2026)
and reported that it opened, played video and streamed a torrent. That is one set, told to us,
not seen by us. Two other testers could not start it at all: their TVs are on an older webOS,
which is the limit described next. Everything in it was written from LG's source, from other
open-source players for webOS, and from what could be tested on a PC. "What is proven" below
says how far each part got.

## Which TVs

Only TVs on **webOS 26 ("Re:New")** or newer, in Developer Mode.

That is LG's limit, not this app's: their Flutter engine and the program it is built into need
the C library of webOS 26 (glibc 2.38; webOS 24 and 25 have 2.35, a 2018 set on webOS 4 has
2.24), and LG's SDK is written for it. LG's Re:New programme brings webOS 26 to 2022 and newer
OLED and upper QNED sets as updates roll out.

**Check before installing.** On the TV: Settings > General > About this TV (or Support > TV
information), "webOS TV version". On the PC: `ares-device --system-info --device <tv>`; its
`sdkVersion` is 11 or higher on webOS 26 (10 is webOS 25, 9 is 24, 8 is 23, 7 is 22, 6 and
below are 2021 and older sets).

### On an older webOS: static, a black screen, or "Not Programmed"

The package installs on any webOS TV, and on an older one it cannot start: the TV's own loader
refuses the program before a line of the app has run, the app never appears among the running
apps, and the TV goes back to what it was showing, which for a set with no aerial is static or
"Not Programmed". It is not a fault of how it was installed, and installing again changes
nothing. To see the TV say so itself:

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

The runtime itself (glibc and the C++ library) is something a package can bring along and
start itself under, with a loader of its own; the TV's libraries then run on top of the newer
runtime, which is the direction that works. Nobody has done that for a 32-bit webOS app that we
could find, and it has not been tried here. It is the way to older sets if they are to be
reached, most plainly webOS 24 and 25.

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

The package comes out as `build/webos/com.vyse.vysetv_<version>_arm.ipk`.

Without a Linux machine: a push to GitHub whose message has `[webos]` builds the same package
there (the `webos` job in `.github/workflows/build.yml`) and keeps it as the run's artifact for
two days. That job runs only once the repository variable `LG_NDK_LICENSE` is set to
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

   or build and install in one go: `tool/webos/build.sh --install <tv>`.

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
  second decoder), picture-in-picture, external players, voice calls in a party, alert tones.

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
| The package (.ipk) | Built by `tool/webos/build.sh` on GitHub (26 November 2026): 55 MB, 32-bit ARM, the app's code stamped for LG's engine, the torrent engine marked as a program. Opened and checked; never installed |
| Anything on a TV | Never run |

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
