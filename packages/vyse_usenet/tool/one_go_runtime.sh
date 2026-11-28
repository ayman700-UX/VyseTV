#!/usr/bin/env bash
# Checks a built iPhone or Apple TV app (its Runner.app folder) holds exactly ONE Go runtime, and
# that the torrent engine and the Usenet engine are both in it. Run by the ios and tvos jobs of
# .github/workflows/build.yml after the build.
#
# Each Go program carries its own runtime. Two in one app is not supported by Go: in 1.0.4 the
# Apple TV app linked two (the torrent engine's and the Usenet engine's) into its one program,
# where they shared the C helpers a runtime starts its threads with, and the app died at launch.
# Both engines are now one Go program (packages/vyse_usenet/apple).
#
#   bash one_go_runtime.sh <path to Runner.app>
set -euo pipefail

APP="${1:?the app's folder (Runner.app)}"
runtimes=0
helpers=0
torrent=""
usenet=""
while IFS= read -r -d '' f; do
  # (Mach-O files only: the program and every framework's binary)
  file -b "$f" | grep -q 'Mach-O' || continue
  symbols="$(nm -a "$f" 2>/dev/null || true)"
  r=$(printf '%s\n' "$symbols" | grep -c ' __rt0_arm64_ios_lib$' || true)
  h=$(printf '%s\n' "$symbols" | grep -c ' T _x_cgo_init$' || true)
  if [ "$r" -gt 0 ] || [ "$h" -gt 0 ]; then
    echo "Go in ${f#"$APP/"}: $r runtime start(s), $h thread helper(s)"
  fi
  runtimes=$((runtimes + r))
  helpers=$((helpers + h))
  printf '%s\n' "$symbols" | grep -q ' T _TorrServerStart$' && torrent="${f#"$APP/"}"
  printf '%s\n' "$symbols" | grep -q ' T _VyseUsenetStart$' && usenet="${f#"$APP/"}"
done < <(find "$APP" -type f -perm -u+x -print0)

echo "Go runtimes in the app: $runtimes (thread helpers: $helpers)"
echo "torrent engine: ${torrent:-MISSING}; Usenet engine: ${usenet:-MISSING}"
if [ "$runtimes" -ne 1 ] || [ "$helpers" -gt 1 ]; then
  echo "::error::The app must hold exactly one Go runtime (found $runtimes, with $helpers thread helpers): two crash it at launch. Both engines belong in one Go library (packages/vyse_usenet/apple)."
  exit 1
fi
if [ -z "$torrent" ] || [ -z "$usenet" ]; then
  echo "::error::An engine is missing from the app (torrent: ${torrent:-no}, Usenet: ${usenet:-no})."
  exit 1
fi
if [ "$torrent" != "$usenet" ]; then
  echo "::error::The two engines are in different files ($torrent, $usenet): they must be one Go library."
  exit 1
fi
echo "One Go runtime, both engines in $torrent."
