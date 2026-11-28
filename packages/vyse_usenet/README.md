# vyse_usenet

VyseTV's Usenet engine: it plays a release straight from Usenet. Given an NZB (from the user's
own Newznab indexers) and the user's own NNTP providers, it serves the video inside as an
ordinary seekable HTTP stream on `127.0.0.1`, which the player opens like any link. Nothing goes
through a VyseTV server, and nothing of the video is written to disk.

It is a Go program run beside the app, the way the torrent engine (TorrServer) is:

| Platform | How it runs | File (in `binaries/`) |
| --- | --- | --- |
| Android, Android TV | a program the app starts from its native library folder | `android-<abi>/libvyse_usenet.so` |
| Windows | a program next to the app | `windows-amd64/vyse-usenet.exe` |
| Linux | a program inside the AppImage | `linux-<arch>/vyse-usenet` |
| macOS | a program inside the app bundle (Intel and Apple silicon) | `darwin-universal/vyse-usenet` |
| LG TVs (webOS) | a program in the package, linked statically | `webos-arm/vyse-usenet` |
| Samsung TVs (Tizen) | a library loaded into the app's process | `tizen-arm/libvyse_usenet.so` |
| iPhone/iPad, Apple TV | a library linked into the app | `ios-arm64/VyseUsenet-ios.xcframework.zip`, `tvos-arm64/VyseUsenet-tvos.xcframework.zip` |

## Talking to it

A program reads one JSON bootstrap record on stdin and answers one line on stdout:

    stdin   {"token": "<at least 32 random characters>", "certificates": ["<PEM>", ...],
             "memoryMiB": 256, "nzbCacheDir": "<a private folder>"}
    stdout  {"protocol": 1, "port": 41234}

It serves on `127.0.0.1:<port>` until stdin closes (so it ends when the app does, however the
app ends). Inside the app's own process, `VyseUsenetStart(bootstrap)` takes the same record and
answers the port; `VyseUsenetStop()` ends it.

Control requests carry `Authorization: Bearer <token>`: `POST /sessions` opens an NZB with the
providers to read it from and answers capability URLs for the video (and subtitles), which the
player reads with ordinary byte-range requests; `GET /sessions/<id>/diagnostics` and
`DELETE /sessions/<id>` follow. `engine/internal/engine/server.go` has the request and answer
fields.

## Building

    python3 tool/build_engine.py <target> <output folder>

The GitHub workflow `.github/workflows/usenet-engine.yml` builds every target and runs the
engine's tests (`go test ./...` in `engine/`); a push whose message has `[usenet-engine]`
starts it. Its results are committed to `binaries/`.

`NOTICE.md` has the licence and the open-source code the engine is built from.
