# VyseTV on Samsung TVs (Tizen)

The app's Tizen side: a C# app (a Samsung TV takes no other kind) that starts Flutter. Everything
VyseTV does is the same Dart as on every other platform; what differs on a Samsung TV is asked at
run time (`lib/core/platform/tizen_tv.dart`, from the build's `--dart-define=VYSE_TIZEN=true`).

Video plays through the TV's own player, by Samsung's plugin for it (`video_player_avplay`), in
`lib/mpv/player/platform/player_tizen.dart`: the TV fetches, decodes and shows the picture under
the app, with its own HDR and sound settings. Audio tracks switch in the TV's player. Subtitle
tracks inside the video are switched on there and drawn by the app (text, and the pictures a
Blu-ray's subtitles are); subtitle files are read and drawn by the app, in time with the film.

## Which package for which TV

Samsung's player plugin carries a library for each Tizen version, so there is a package for each:

| Package | Tizen | Samsung TVs from |
|:-|:-|:-|
| `VyseTV-<version>-tizen6.0.tpk` | 6.0 | 2021 |
| `VyseTV-<version>-tizen6.5.tpk` | 6.5 to 9.0 | 2022, 2023, 2024, 2025 |
| `VyseTV-<version>-tizen10.0.tpk` | 10.0 | 2026 |

TVs from before 2021 (Tizen 5.5 and older) are not covered: flutter-tizen and Samsung's player
plugin start at Tizen 6.0.

## Building

On GitHub: a push whose message has `[tizen]` (the `tizen` job in .github/workflows/build.yml).
The packages are the job's `vysetv-tizen` artifact. On a Linux PC (Ubuntu 22.04):

    bash tool/tizen/setup.sh --accept-tizen-sdk-license
    bash tool/tizen/build.sh            # or: bash tool/tizen/build.sh 6.5

`setup.sh` installs the Tizen SDK's command-line tools, flutter-tizen at the release made from
this project's own Flutter (3.47.1), and a signing profile with a certificate made there.
`build.sh` builds each package in its own copy of the app (`tool/tizen/stage.py`, which adds the
Tizen sides of a few plugins without touching the repository's pubspec) and looks inside it.

## Putting it on a TV

1. On the TV: Apps, then type 1 2 3 4 5 with the remote. Turn Developer mode on, enter the
   computer's address (Host PC IP), and restart the TV.
2. On the computer, with the Tizen SDK's tools (the VS Code extension for Tizen, or the
   command-line tools `setup.sh` installs):

       sdb connect <the TV's address>
       tizen install -n VyseTV-<version>-tizen6.5.tpk -t <the TV's name from: sdb devices>

The packages are signed with a certificate made on GitHub. Many TVs, the newer ones above all,
install only a package signed with a Samsung certificate made for that TV (it names the TV's
DUID). Then: in the Tizen tools' Certificate Manager, make a Samsung certificate with the TV
connected (its DUID is filled in), and sign the package again with it:

    tizen package -t tpk -s <your certificate profile> -- VyseTV-<version>-tizen6.5.tpk

## What is proven

- The packages are built on GitHub, and each is looked inside (`tool/tizen/look_inside.py`).
- The player's logic is tested on a PC with a stand-in for Samsung's plugin
  (`test/tizen_player_test.dart`): opening, where it starts, the tracks, switching the audio
  track, subtitles inside the video (text and pictures) and from files, the subtitle delay,
  seeking, speed, the end of a film, faults, where the picture goes, and the app going to the
  background and back.
- One tester's 2025 set on Tizen 8 (27 November 2026, the Tizen 6.5 package): it installs and
  starts every time, the remote works (slow at times), and video plays. Three things went wrong,
  each changed since and not yet tried there:
  - After fast-forwarding, the subtitles went out of step, and "Playback stopped (Not supported
    media format)" stayed on screen over a film that played on. The TV's player reports faults
    it carries on from, and any of them ended the film here. Now a fault ends the film only if
    the TV's player has really stopped, and the subtitles follow the TV's own position rather
    than its playing and loading events.
  - VyseTV's own servers' links stopped with a line of the TV's media framework
    (`gstbasesrc.c … gst_base_src_loop`). Not explained yet. The relay on the TV now names each
    piece of a stream by what it is (`.ts`, `.m4s`, `.vtt`) and sends it with that type, the
    fault is shown in words, and the report card says what the TV's player asked of the relay
    and what the real address answered.
  - AIOStreams' own messages (its "[❌]" entries when a debrid service fails) showed as sources
    that open in the browser, and the browser closed again. They are shown as messages now, and
    on a TV a web link is a QR code to open on a phone.
- The second round on the same set (27 November, later): a 4K film after a while of browsing
  ended the app (the TV's out-of-memory killer); music looked songs up and never played them;
  catalogues and lists were slow; season numbers sat over Play and Save, and "History" was cut
  to "Historv"; the hero's picture came seconds after its words; an id under every Live TV
  channel; two outlines on the playing channel; the keyboard over Manga's search. Changed since,
  not yet tried there: the app is laid out at 960 by 540 points as on an Android TV
  (`App.cs` sets the scale; Samsung's engine gave a TV 1.6, so 1200 by 675) and text at the
  app's own size; while a film plays, the pictures nothing shows are let go (the TV's player
  shares the app's memory: `lib/core/platform/tv_memory.dart`); the hero takes TMDB's 1280-wide
  picture; big addon answers are read off the interface's thread; ids are left out of guide
  lines; a focused text box goes to the top part of the page. Music is not explained yet: the
  TV's player may not take the audio format the lookup chooses.
- Scraper plugins and torrents are built for the TV and not reported on yet: the engine inside a
  C# app's process is the least certain part. Samsung's player plugin does not run on the TV
  emulator, so there is no video without a real TV.

## The TV's own libraries

Besides Flutter's, each package carries two libraries built for the TV by
`tool/tizen/native.sh` (32-bit ARM, against Tizen 6.0, so they load on every newer TV too):

- `libquickjs_c_bridge_plugin.so`: the JavaScript engine scraper plugins run in (QuickJS, from
  the commit the LG build uses), built by the Tizen SDK's own `tizen build-native`.
- `libtorrserver.so`: the torrent engine, inside the app's process (a Samsung TV starts no
  program of an app's own). Started through dart:ffi, it answers this TV only (127.0.0.1).
  Torrents show in the app only when the package has it.

## A party

Voice calls go through Samsung's own WebRTC for Tizen (`flutter_webrtc_tizen`): a TV with no
microphone is in the call listening; one with a USB microphone talks (the recorder privilege).
The party's sounds play through Tizen's WAV player, as a notification's sound, so they never
take the film's player.

## Not in the Samsung build

- Downloads: on no TV (Android TV, LG and Apple TV neither).
- Updates from inside the app: a TV can't put a package in place by itself. When there is a new
  version, the update box shows a QR code; a phone opens the release page, which says which file
  is for this TV, and it goes on the TV the way the first one did.
- Fill (crop to the screen) and zooming in show the picture cropped only when the video fills
  the whole screen; in a smaller box the whole picture shows.

## What to send back

1. The TV's model and year, and which package was put on.
2. Does it install and open? If not, what the install or the TV said.
3. If it opens: does a video play, with sound; does switching the audio track work; do
   subtitles show (a track inside the video, and one picked from the subtitle list); does the
   picture sit right; does Back, Play/Pause and seeking work; does a sign-in stay after the TV
   is turned off and on; does a scraper plugin find links; does a torrent play.
4. If a video does not play: a photo of the player's report card (Stream info, or Settings >
   Playback > Last playback).
