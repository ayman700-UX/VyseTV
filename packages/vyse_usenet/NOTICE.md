# The Usenet engine: licence and the code it is built from

`engine/` is a Usenet streaming engine under the GNU General Public License version 3
(`engine/LICENSE`), as VyseTV is. It turns an NZB and the user's NNTP provider settings into
seekable HTTP streams on `127.0.0.1`.

It adapts the progressive shared-article model, NZB planning, lazy archive strategy, RAR volume
naming and the NNTP test harness of [AltMount](https://github.com/kipsilabs/altmount), commit
`3fd79fad97772d193b6916e316753b9a267c6520` (MIT, Javier Blanco). AltMount's licence is in
`engine/licenses/AltMount-MIT.txt`.

| Source | Version | Use / local changes |
| --- | --- | --- |
| javi11/nntppool | v4.23.0, MIT | Vendored pipelined NNTP pool (`engine/third_party/nntppool`). Commits buffered replies before writing decoded bytes; suppresses callbacks for abandoned attempts; joins the reader before reusing a connection's slab. |
| javi11/nzbparser | v0.5.5, MIT | Subject parsing; XML handling adapted to decode one NZB file at a time and keep addon file indices. |
| javi11/rardecode | v2.2.4, BSD | RAR4/RAR5 header fields, stored-data extent mapping, header/file encryption records and the RAR4/RAR5 AES key schedules. No decompression code is included. |
| mnightingale/rapidyenc | 7aafef1eaf1c, MIT | Chunked yEnc wrapper (`engine/third_party/rapidyenc`). |
| animetosho/rapidyenc | 480bd7b5896f8b3edecc721d23f1384d767ffe2f, public domain / CC0 | Native SIMD yEnc kernels (`engine/third_party/rapidyenc-native`), compiled for each platform by `tool/build_engine.py`. CRC disabled; Go's CRC32 checks articles. |
| dlclark/regexp2 | v2.7.2, MIT | ECMAScript file selectors from addons, with bounded matching time. |
| javi11/sevenzip | ca961b7f1239 (fork of bodgit/sevenzip), BSD | 7z directory parsing only, including LZMA-compressed and AES-encrypted headers. Linked: andybalholm/brotli (MIT), bodgit/plumbing and bodgit/windows (BSD), hashicorp/golang-lru (MPL-2.0), klauspost/compress (BSD), pierrec/lz4 (BSD), spf13/afero (Apache-2.0), ulikunitz/xz (BSD), go4.org (Apache-2.0). |

Every licence is in `engine/licenses/`, and `engine/third_party` keeps the upstream notices.
The app ships `engine/licenses/` with the engine.

## Changes made for VyseTV

- The module is `vyse/usenet`, the program `cmd/vyse-usenet`, the Android executable
  `libvyse_usenet.so`.
- `cmd/libvyse-usenet`: the same engine started inside the app's own process (C entry points
  `VyseUsenetStart`, `VyseUsenetStop`, `VyseUsenetError`), for iPhone/iPad, Apple TV and
  Samsung TVs, which may not start a program of an app's own.
- `third_party/rapidyenc/cgo.go`: link rules for iPhone/Apple TV (`librapidyenc_ios_arm64.a`)
  and 32-bit ARM Linux (`librapidyenc_linux_arm.a`, LG and Samsung TVs); macOS's rule no longer
  applies to iOS.
