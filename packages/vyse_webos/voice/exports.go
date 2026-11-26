//go:build cgo

// What the app calls (lib/data/party/voice_lg.dart, through dart:ffi). Every string handed
// back is the caller's to free with VyseVoiceFree; NULL means no error.
package main

/*
#include <stdlib.h>
*/
import "C"

import "unsafe"

//export VyseVoiceJoin
func VyseVoiceJoin(url, token *C.char) {
	join(C.GoString(url), C.GoString(token))
}

//export VyseVoiceLeave
func VyseVoiceLeave() {
	leave()
}

//export VyseVoiceState
func VyseVoiceState() *C.char {
	return C.CString(snapshotJSON())
}

//export VyseVoiceSetDeafened
func VyseVoiceSetDeafened(on C.int) {
	mu.Lock()
	deafened = on != 0
	mu.Unlock()
}

//export VyseVoiceSetVolume
func VyseVoiceSetVolume(identity *C.char, volume C.double) {
	mu.Lock()
	volumes[C.GoString(identity)] = float64(volume)
	mu.Unlock()
}

//export VyseVoicePlayWav
func VyseVoicePlayWav(path *C.char, volume C.double) *C.char {
	if err := playWav(C.GoString(path), float64(volume)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export VyseVoiceFree
func VyseVoiceFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}
