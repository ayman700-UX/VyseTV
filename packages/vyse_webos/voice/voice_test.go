package main

import (
	"encoding/binary"
	"testing"
)

func TestRedPrimary(t *testing.T) {
	// one redundant block of 3 bytes (F=1, PT 111, offset 960, length 3), then the primary
	// header (F=0, PT 111): data is the redundant 3 bytes, then the primary payload
	p := []byte{0x80 | 111, 0x0F, 0x00, 0x03, 111, 0xAA, 0xBB, 0xCC, 1, 2, 3, 4}
	got := redPrimary(p)
	if string(got) != string([]byte{1, 2, 3, 4}) {
		t.Fatalf("primary = %v", got)
	}
	// no redundancy: just the one-byte header
	if got := redPrimary([]byte{111, 9, 8}); string(got) != string([]byte{9, 8}) {
		t.Fatalf("plain = %v", got)
	}
	// cut short: nothing
	if got := redPrimary([]byte{0x80 | 111, 0x0F}); got != nil {
		t.Fatalf("short = %v", got)
	}
}

func wav(rate, chans int, samples []int16) []byte {
	data := make([]byte, len(samples)*2)
	for i, s := range samples {
		binary.LittleEndian.PutUint16(data[i*2:], uint16(s))
	}
	b := []byte("RIFF\x00\x00\x00\x00WAVEfmt ")
	f := make([]byte, 4+16)
	binary.LittleEndian.PutUint32(f[0:], 16)
	binary.LittleEndian.PutUint16(f[4:], 1)
	binary.LittleEndian.PutUint16(f[6:], uint16(chans))
	binary.LittleEndian.PutUint32(f[8:], uint32(rate))
	binary.LittleEndian.PutUint32(f[12:], uint32(rate*chans*2))
	binary.LittleEndian.PutUint16(f[16:], uint16(chans*2))
	binary.LittleEndian.PutUint16(f[18:], 16)
	b = append(b, f...)
	b = append(b, []byte("data")...)
	n := make([]byte, 4)
	binary.LittleEndian.PutUint32(n, uint32(len(data)))
	b = append(b, n...)
	return append(b, data...)
}

func TestWavTo48kStereo(t *testing.T) {
	// 24 kHz mono, 4 samples: 8 stereo frames at 48 kHz, each sample twice, left = right
	pcm, err := wavTo48kStereo(wav(24000, 1, []int16{100, 200, 300, 400}))
	if err != nil {
		t.Fatal(err)
	}
	if len(pcm) != 16 {
		t.Fatalf("len = %d", len(pcm))
	}
	if pcm[0] != 100 || pcm[1] != 100 || pcm[2] != 100 || pcm[4] != 200 || pcm[14] != 400 {
		t.Fatalf("pcm = %v", pcm)
	}
	if _, err := wavTo48kStereo([]byte("not a wav file at all")); err == nil {
		t.Fatal("took a non-WAV")
	}
}

func TestMixFrame(t *testing.T) {
	mu.Lock()
	state, deafened = "on", false
	volumes = map[string]float64{"b": 0.5}
	full := func(v int16) []int16 {
		f := make([]int16, frameLen)
		for i := range f {
			f[i] = v
		}
		return f
	}
	a := &voice{who: "a", queue: [][]int16{full(1000), full(1000), full(1000)}}
	b := &voice{who: "b", queue: [][]int16{full(30000), full(30000), full(30000)}}
	short := &voice{who: "c", queue: [][]int16{full(5)}} // fewer than the prebuffer: not heard yet
	voices = map[string]*voice{"A": a, "B": b, "C": short}
	tones = nil
	mu.Unlock()

	acc, mix := make([]int32, frameLen), make([]int16, frameLen)
	if !mixFrame(acc, mix) {
		t.Fatal("a call is something to play")
	}
	if mix[0] != 1000+15000 {
		t.Fatalf("mixed = %d", mix[0])
	}
	if len(a.queue) != 2 || len(short.queue) != 1 {
		t.Fatalf("queues: %d %d", len(a.queue), len(short.queue))
	}

	// loud enough to clip
	volumes["b"] = 2
	mixFrame(acc, mix)
	if mix[0] != 32767 {
		t.Fatalf("not clipped: %d", mix[0])
	}

	// deafened: silence, though the call goes on
	deafened = true
	if !mixFrame(acc, mix) || mix[0] != 0 {
		t.Fatalf("deafened = %d", mix[0])
	}
	mu.Lock()
	state, deafened, voices = "off", false, map[string]*voice{}
	mu.Unlock()
	if mixFrame(acc, mix) {
		t.Fatal("nothing to play when off")
	}
}
