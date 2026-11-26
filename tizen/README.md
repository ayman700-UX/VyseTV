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
- Nothing has run on a Samsung TV yet. Samsung's player plugin does not run on the TV emulator,
  so there is no video without a real TV.

## Not in the Samsung build

- Downloads (little room on a TV, and its player is never handed a file).
- Torrents: the engine is a program of its own beside the app, and a Samsung TV runs no program
  Samsung has not signed.
- Voice calls in a party, and party sounds.
- JavaScript scraper plugins: their engine's library is not built for Tizen yet.
- Updates from inside the app: a new package is installed as the first one was.
- Fill (crop to the screen) and zooming in show the picture cropped only when the video fills
  the whole screen; in a smaller box the whole picture shows.

## What to send back

1. The TV's model and year, and which package was put on.
2. Does it install and open? If not, what the install or the TV said.
3. If it opens: does a video play, with sound; does switching the audio track work; do
   subtitles show (a track inside the video, and one picked from the subtitle list); does the
   picture sit right; does Back, Play/Pause and seeking work; does a sign-in stay after the TV
   is turned off and on.
4. If a video does not play: a photo of the player's report card (Stream info, or Settings >
   Playback > Last playback).
