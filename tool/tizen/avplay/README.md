# Samsung's player plugin, as VyseTV builds it

The Samsung TV packages play video through `video_player_avplay` 0.8.23. That is Samsung's own
Flutter plugin, from github.com/flutter-tizen/plugins, under its BSD licence; see its LICENSE.

`tool/tizen/stage.py` takes that release from pub.dev and checks its SHA-256. It then lays the
files in `src/` over the plugin's `tizen/src/` in the build copy. Nothing else changes, and the
app's Dart sees the published plugin. Each change is marked "VyseTV" in the files.

## Why

A tester's Tizen 6.5 TV played nothing (2026-11-28). Every video stayed on the poster with a
spinner, with no sound and no error. The plugin hands a web address to the TV's streaming player
(PlusPlayer). Reading its source showed two ways it could wait forever:

- When preparation fails, it says nothing. That happens, for example, when the TV refuses a
  system library to an app signed with an ordinary certificate (flutter-tizen/plugins#1206,
  #626).
- It asks once whether the player is ready, as the app starts listening. Some Tizen 6 TVs reach
  READY without ever calling back. The other app's own Samsung player polls the state for this
  reason.

## The changes

- `video_player.h`, `video_player.cc`: after a video is opened, the player is looked at every
  400 ms for 20 s.
  - READY on two looks in a row without the callback: the app is told the video is ready.
  - A failed preparation: the app gets a `PrepareFailed` error, also when the failure came before
    the app listened.
- `plus_player.cc`: a failed preparation is logged ("Prepare callback: success=0") and marked for
  the above.
- `video_player_tizen_plugin.cc`: `vyseBasicPlayer: true` in `playerOptions` sends a web address
  to the TV's basic media player (the plugin's MediaPlayer, which it otherwise uses only for
  files).

## What the app does with it

`lib/mpv/player/platform/player_tizen.dart`:

- A video the streaming player hasn't started opens again on the basic player, where it was.
  That covers no ready in 20 s, or 45 s for a stream from this TV such as a torrent, and a
  preparation error.
- A TV where that saved two videos in a row starts on the basic player from then on.
- If neither starts it, it ends with the reason, and the report card says which player played.

## Moving to a new plugin release

1. Update `AVPLAY_VERSION` and `AVPLAY_SHA256` in `stage.py`.
2. Copy the new release's four files here and make the same changes again.
3. `look_inside.py` fails a package whose plugin lacks the `vyseBasicPlayer` option.
