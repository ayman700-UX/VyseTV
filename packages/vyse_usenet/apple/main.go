// The iPhone/iPad and Apple TV library: the Usenet engine and the torrent engine in ONE Go
// program, built by ../tool/build_engine.py (targets ios-arm64, tvos-arm64) as one static library
// (-buildmode=c-archive) that the app links once.
//
// Why one: each Go program carries its own Go runtime. In 1.0.4 the two engines were two
// libraries, so the Apple TV app (which links both into its own program) held two Go runtimes
// that shared one set of the C helpers a runtime starts its threads with; the second runtime to
// start took them over and the app died at launch. On an iPhone the two sat in two frameworks,
// which Go does not support either. One program, one runtime: as in 1.0.3, when the torrent
// engine was the only Go in the app.
//
// The Usenet engine's entry points come from vyse/usenet/capi (VyseUsenetStart, VyseUsenetStop,
// VyseUsenetError); the torrent engine's are below, the same as the Samsung TV library's
// (packages/torrserver_flutter/tool/go-shim/cshared). Both sets are declared for Swift in
// packages/vyse_usenet/ios/Classes/VyseUsenetEngine.h.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	torrserverkit "github.com/ayman708-UX/torrserver_flutter/tool/go-shim"
	"vyse/usenet/capi"
)

func init() {
	// (the Usenet engine's memory limit would cover the torrent engine's memory too)
	capi.SharedRuntime = true
}

// TorrServerStart starts the torrent engine on 127.0.0.1-reachable port [port] with its files in
// [dataDir]; an empty [ip] listens on every address. NULL, or why it did not start (the caller
// frees it with TorrServerFree).
//
//export TorrServerStart
func TorrServerStart(port C.int, dataDir *C.char, ip *C.char) *C.char {
	return result(torrserverkit.StartServerOn(int(port), C.GoString(dataDir), C.GoString(ip)))
}

// TorrServerStop stops it: NULL, or why not (freed with TorrServerFree).
//
//export TorrServerStop
func TorrServerStop() *C.char {
	return result(torrserverkit.StopServer())
}

// TorrServerIsRunning is 1 while it runs.
//
//export TorrServerIsRunning
func TorrServerIsRunning() C.int {
	if torrserverkit.IsRunning() {
		return 1
	}
	return 0
}

// TorrServerFree frees a string the torrent entry points handed back.
//
//export TorrServerFree
func TorrServerFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func result(err string) *C.char {
	if err == "" {
		return nil
	}
	return C.CString(err)
}

func main() {}
