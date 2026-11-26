//go:build cgo

// Opus decoding with libopus, linked in statically (build.sh builds it for the TV with LG's
// compiler: packages/vyse_webos/voice/build.sh).
package main

/*
#cgo LDFLAGS: -lopus -lm
#include <opus/opus.h>
#include <stdlib.h>

static int vyse_opus_decode(OpusDecoder *d, const unsigned char *data, int len, short *pcm, int frames) {
	return opus_decode(d, data, len, pcm, frames, 0);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

type opusDecoder struct{ d *C.OpusDecoder }

func newDecoder() (decoder, error) {
	var err C.int
	d := C.opus_decoder_create(C.opus_int32(sampleRate), C.int(channels), &err)
	if err != C.OPUS_OK || d == nil {
		return nil, fmt.Errorf("opus decoder: %d", int(err))
	}
	return &opusDecoder{d: d}, nil
}

func (o *opusDecoder) Decode(packet []byte, pcm []int16) (int, error) {
	if o.d == nil {
		return 0, errors.New("closed")
	}
	frames := len(pcm) / channels
	var n C.int
	if len(packet) == 0 {
		n = C.vyse_opus_decode(o.d, nil, 0, (*C.short)(unsafe.Pointer(&pcm[0])), C.int(frames))
	} else {
		n = C.vyse_opus_decode(o.d, (*C.uchar)(unsafe.Pointer(&packet[0])), C.int(len(packet)), (*C.short)(unsafe.Pointer(&pcm[0])), C.int(frames))
	}
	if n < 0 {
		return 0, fmt.Errorf("opus: %d", int(n))
	}
	return int(n), nil
}

func (o *opusDecoder) Close() {
	if o.d != nil {
		C.opus_decoder_destroy(o.d)
		o.d = nil
	}
}
