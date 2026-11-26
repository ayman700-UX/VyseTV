/// VyseTV's native side on LG webOS.
///
/// There is no Dart in this package: it exists for its C++ (`webos/`), which LG's Flutter tool
/// builds into the app. What it offers is reached by channel name from the app itself:
///
///  * `vyse/webos_media/<slot>` and `vyse/webos_media/<slot>/events`, one pair for each of the
///    three players the app keeps (0 the film, 1 music, 2 a party's music): the TV's own media
///    player, driven by `lib/mpv/player/platform/player_webos.dart`.
///  * `vyse/webos_window`: properties of the app's window, which is how the remote's Back key
///    is asked for (`lib/core/platform/webos_window.dart`).
library;
