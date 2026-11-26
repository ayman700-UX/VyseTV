//go:build cgo

// The TV's sound: ALSA's default device, or PulseAudio when ALSA does not open (webOS runs
// PulseAudio; which one an app may use is the TV's to say). Both are opened when first needed,
// by name, with only the few functions used here declared below: the library links against
// neither, and a TV without one still gets the other.
package main

/*
#cgo LDFLAGS: -ldl
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>

// ALSA, as far as used (alsa-lib's own values)
typedef struct _snd_pcm snd_pcm_t;
#define VYSE_SND_PCM_STREAM_PLAYBACK 0
#define VYSE_SND_PCM_FORMAT_S16_LE 2
#define VYSE_SND_PCM_ACCESS_RW_INTERLEAVED 3

static void *alsa;
static int (*a_open)(snd_pcm_t **, const char *, int, int);
static int (*a_set_params)(snd_pcm_t *, int, int, unsigned int, unsigned int, int, unsigned int);
static long (*a_writei)(snd_pcm_t *, const void *, unsigned long);
static int (*a_recover)(snd_pcm_t *, int, int);
static int (*a_drain)(snd_pcm_t *);
static int (*a_close)(snd_pcm_t *);

static void *vyse_alsa_open(unsigned int rate, unsigned int channels, int *err) {
	if (!alsa) {
		alsa = dlopen("libasound.so.2", RTLD_NOW);
		if (!alsa) { *err = -1000; return NULL; }
		a_open = dlsym(alsa, "snd_pcm_open");
		a_set_params = dlsym(alsa, "snd_pcm_set_params");
		a_writei = dlsym(alsa, "snd_pcm_writei");
		a_recover = dlsym(alsa, "snd_pcm_recover");
		a_drain = dlsym(alsa, "snd_pcm_drain");
		a_close = dlsym(alsa, "snd_pcm_close");
		if (!a_open || !a_set_params || !a_writei || !a_recover || !a_close) { *err = -1001; return NULL; }
	}
	snd_pcm_t *pcm = NULL;
	int r = a_open(&pcm, "default", VYSE_SND_PCM_STREAM_PLAYBACK, 0);
	if (r < 0) { *err = r; return NULL; }
	// (100 ms of buffer: the mixer writes 20 ms at a time)
	r = a_set_params(pcm, VYSE_SND_PCM_FORMAT_S16_LE, VYSE_SND_PCM_ACCESS_RW_INTERLEAVED, channels, rate, 1, 100000);
	if (r < 0) { a_close(pcm); *err = r; return NULL; }
	*err = 0;
	return pcm;
}

static int vyse_alsa_write(void *pcm, const int16_t *data, unsigned long frames) {
	while (frames > 0) {
		long n = a_writei((snd_pcm_t *)pcm, data, frames);
		if (n < 0) {
			n = a_recover((snd_pcm_t *)pcm, (int)n, 1);
			if (n < 0) return (int)n;
			continue;
		}
		data += n * 2;
		frames -= (unsigned long)n;
	}
	return 0;
}

static void vyse_alsa_close(void *pcm) {
	if (a_drain) a_drain((snd_pcm_t *)pcm);
	a_close((snd_pcm_t *)pcm);
}

// PulseAudio's simple API, as far as used (its own values)
typedef struct pa_simple pa_simple;
typedef struct { int format; uint32_t rate; uint8_t channels; } vyse_pa_sample_spec;
#define VYSE_PA_SAMPLE_S16LE 3
#define VYSE_PA_STREAM_PLAYBACK 1

static void *pulse;
static pa_simple *(*p_new)(const char *, const char *, int, const char *, const char *, const vyse_pa_sample_spec *, const void *, const void *, int *);
static int (*p_write)(pa_simple *, const void *, size_t, int *);
static int (*p_drain)(pa_simple *, int *);
static void (*p_free)(pa_simple *);

static void *vyse_pulse_open(unsigned int rate, unsigned int channels, int *err) {
	if (!pulse) {
		pulse = dlopen("libpulse-simple.so.0", RTLD_NOW);
		if (!pulse) { *err = -2000; return NULL; }
		p_new = dlsym(pulse, "pa_simple_new");
		p_write = dlsym(pulse, "pa_simple_write");
		p_drain = dlsym(pulse, "pa_simple_drain");
		p_free = dlsym(pulse, "pa_simple_free");
		if (!p_new || !p_write || !p_free) { *err = -2001; return NULL; }
	}
	vyse_pa_sample_spec ss = { VYSE_PA_SAMPLE_S16LE, rate, (uint8_t)channels };
	return p_new(NULL, "VyseTV", VYSE_PA_STREAM_PLAYBACK, NULL, "Party voice", &ss, NULL, NULL, err);
}

static int vyse_pulse_write(void *s, const int16_t *data, size_t bytes) {
	int err = 0;
	if (p_write((pa_simple *)s, data, bytes, &err) < 0) return err ? -err : -1;
	return 0;
}

static void vyse_pulse_close(void *s) {
	int err;
	if (p_drain) p_drain((pa_simple *)s, &err);
	p_free((pa_simple *)s);
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

type alsaOut struct{ h unsafe.Pointer }

func (a *alsaOut) Write(p []int16) error {
	if r := C.vyse_alsa_write(a.h, (*C.int16_t)(unsafe.Pointer(&p[0])), C.ulong(len(p)/channels)); r < 0 {
		return fmt.Errorf("alsa write: %d", int(r))
	}
	return nil
}

func (a *alsaOut) Close() { C.vyse_alsa_close(a.h) }

type pulseOut struct{ h unsafe.Pointer }

func (p *pulseOut) Write(s []int16) error {
	if r := C.vyse_pulse_write(p.h, (*C.int16_t)(unsafe.Pointer(&s[0])), C.size_t(len(s)*2)); r < 0 {
		return fmt.Errorf("pulse write: %d", int(r))
	}
	return nil
}

func (p *pulseOut) Close() { C.vyse_pulse_close(p.h) }

func openOutput(rate, chans int) (output, string, error) {
	var aerr, perr C.int
	if h := C.vyse_alsa_open(C.uint(rate), C.uint(chans), &aerr); h != nil {
		return &alsaOut{h: h}, "alsa", nil
	}
	if h := C.vyse_pulse_open(C.uint(rate), C.uint(chans), &perr); h != nil {
		return &pulseOut{h: h}, "pulse", nil
	}
	return nil, "", fmt.Errorf("alsa %d, pulse %d", int(aerr), int(perr))
}
