// The torrent engine as a shared library with C entry points, for a system where the app
// can neither start a program of its own beside it nor link a framework (a Samsung TV: Tizen).
// Built by build-tizen-so.sh with `go build -buildmode=c-shared`; the app's Dart calls these
// through dart:ffi (lib/src/torrserver_controller_ffi.dart).
//
// Every string handed back is the caller's to free with TorrServerFree; NULL means no error.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	torrserverkit "github.com/ayman708-UX/torrserver_flutter/tool/go-shim"
)

//export TorrServerStart
func TorrServerStart(port C.int, dataDir *C.char, ip *C.char) *C.char {
	return result(torrserverkit.StartServerOn(int(port), C.GoString(dataDir), C.GoString(ip)))
}

//export TorrServerStop
func TorrServerStop() *C.char {
	return result(torrserverkit.StopServer())
}

//export TorrServerIsRunning
func TorrServerIsRunning() C.int {
	if torrserverkit.IsRunning() {
		return 1
	}
	return 0
}

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
