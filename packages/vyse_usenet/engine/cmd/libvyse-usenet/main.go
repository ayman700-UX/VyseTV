// The engine as a library with C entry points (the package capi), for a Samsung TV, where the
// app loads it into its own process (a Samsung TV starts no program of an app's own): a shared
// library, -buildmode=c-shared. The iPhone and Apple TV library is ../../../apple, which holds the
// torrent engine too.
package main

import _ "vyse/usenet/capi"

func main() {}
