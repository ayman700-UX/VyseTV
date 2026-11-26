// A party's voice call on an LG TV, listening: VyseTV's own small LiveKit client.
//
// The app's voice calls are LiveKit over WebRTC (lib/data/party/voice.dart), and there is no
// WebRTC library for an LG TV's 32-bit ARM, nor any microphone LG gives an app. So on LG the
// app joins the call through this library instead: LiveKit's own Go SDK (pion WebRTC, pure Go)
// receives everyone's audio, Opus is decoded (libopus, cgo_opus.go), the voices are mixed here
// with each person's volume, and the result goes to the TV's sound (ALSA or PulseAudio,
// cgo_audio.go). Nothing is sent. The party's short sounds (join, leave, a message) play
// through the same output, call or not.
//
// The app calls it through dart:ffi (exports.go); what the call looks like (who is in it, who
// is talking) it reads as JSON, a few times a second.
package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	lksdk "github.com/livekit/server-sdk-go/v2"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

func main() {}

const (
	sampleRate = 48000
	channels   = 2
	frame      = sampleRate / 50 // 20 ms per channel
	frameLen   = frame * channels
	maxQueue   = 10 // frames kept per voice (200 ms): more than that is late, and dropped
	prebuffer  = 3  // frames a voice gathers before it is heard (60 ms against jitter)
)

// ── what the app reads ──

type snapshot struct {
	State    string          `json:"state"` // off, connecting, on, failed
	Error    string          `json:"error,omitempty"`
	Me       string          `json:"me,omitempty"`
	People   map[string]bool `json:"people"` // identity -> their microphone is on
	Speaking []string        `json:"speaking"`
	Output   string          `json:"output,omitempty"` // which sound system it plays through
}

var (
	mu       sync.Mutex
	state    = "off"
	failure  string
	room     *lksdk.Room
	speaking []string
	deafened bool
	volumes  = map[string]float64{}
	voices   = map[string]*voice{} // track SID -> its audio
	tones    []*tone
)

func snapshotJSON() string {
	mu.Lock()
	defer mu.Unlock()
	s := snapshot{State: state, Error: failure, People: map[string]bool{}, Speaking: speaking, Output: outputName()}
	if s.Speaking == nil {
		s.Speaking = []string{}
	}
	if room != nil {
		if lp := room.LocalParticipant; lp != nil {
			s.Me = lp.Identity()
			s.People[s.Me] = false // (listening: an LG TV gives an app no microphone)
		}
		for _, p := range room.GetRemoteParticipants() {
			on := false
			for _, pub := range p.TrackPublications() {
				if pub.Kind() == lksdk.TrackKindAudio && !pub.IsMuted() {
					on = true
				}
			}
			s.People[p.Identity()] = on
		}
	}
	b, _ := json.Marshal(s)
	return string(b)
}

// ── the call ──

func join(url, token string) {
	mu.Lock()
	if state == "connecting" || state == "on" {
		mu.Unlock()
		return
	}
	state, failure, speaking = "connecting", "", nil
	mu.Unlock()
	go func() {
		cb := lksdk.NewRoomCallback()
		cb.OnTrackSubscribed = onTrack
		cb.OnTrackUnsubscribed = func(track *webrtc.TrackRemote, pub *lksdk.RemoteTrackPublication, rp *lksdk.RemoteParticipant) {
			mu.Lock()
			delete(voices, pub.SID())
			mu.Unlock()
		}
		cb.OnActiveSpeakersChanged = func(ps []lksdk.Participant) {
			ids := make([]string, 0, len(ps))
			for _, p := range ps {
				ids = append(ids, p.Identity())
			}
			sort.Strings(ids)
			mu.Lock()
			speaking = ids
			mu.Unlock()
		}
		cb.OnDisconnected = func() { ended("") }
		r, err := lksdk.ConnectToRoomWithToken(url, token, cb, lksdk.WithAutoSubscribe(true))
		mu.Lock()
		defer mu.Unlock()
		if err != nil {
			state, failure = "failed", err.Error()
			return
		}
		if state != "connecting" { // left while it was connecting
			go r.Disconnect()
			return
		}
		room, state = r, "on"
		startOutput()
	}()
}

func leave() {
	mu.Lock()
	r := room
	room = nil
	state, failure, speaking = "off", "", nil
	voices = map[string]*voice{}
	mu.Unlock()
	if r != nil {
		r.Disconnect()
	}
}

func ended(reason string) {
	mu.Lock()
	defer mu.Unlock()
	if state == "off" {
		return
	}
	room = nil
	voices = map[string]*voice{}
	speaking = nil
	if reason != "" {
		state, failure = "failed", reason
	} else {
		state = "off"
	}
}

// One person's audio: Opus packets decoded into 20 ms frames, queued for the mixer.
type voice struct {
	who     string
	dec     decoder
	queue   [][]int16
	started bool
	lastSeq uint16
	haveSeq bool
}

func onTrack(track *webrtc.TrackRemote, pub *lksdk.RemoteTrackPublication, rp *lksdk.RemoteParticipant) {
	if track.Kind() != webrtc.RTPCodecTypeAudio {
		return
	}
	dec, err := newDecoder()
	if err != nil {
		return
	}
	v := &voice{who: rp.Identity(), dec: dec}
	red := strings.EqualFold(track.Codec().MimeType, "audio/red")
	mu.Lock()
	voices[pub.SID()] = v
	mu.Unlock()
	go func() {
		defer dec.Close()
		pcm := make([]int16, 5760*channels) // the longest Opus packet: 120 ms
		for {
			pkt, _, err := track.ReadRTP()
			if err != nil {
				return
			}
			mu.Lock()
			alive := voices[pub.SID()] == v
			mu.Unlock()
			if !alive {
				return
			}
			payload := pkt.Payload
			if red {
				payload = redPrimary(payload)
			}
			if len(payload) == 0 {
				continue
			}
			v.receive(pkt, payload, pcm)
		}
	}()
}

func (v *voice) receive(pkt *rtp.Packet, payload []byte, pcm []int16) {
	// a lost packet: the decoder makes up what is missing (packet loss concealment)
	if v.haveSeq {
		gap := int(pkt.SequenceNumber - v.lastSeq - 1)
		if gap < 0 || gap > 1000 { // (old, or reordered: dropped)
			return
		}
		for i := 0; i < gap && i < 3; i++ {
			if n, err := v.dec.Decode(nil, pcm[:frameLen]); err == nil && n > 0 {
				v.push(pcm[:n*channels])
			}
		}
	}
	v.lastSeq, v.haveSeq = pkt.SequenceNumber, true
	n, err := v.dec.Decode(payload, pcm)
	if err != nil || n <= 0 {
		return
	}
	v.push(pcm[:n*channels])
}

func (v *voice) push(samples []int16) {
	mu.Lock()
	defer mu.Unlock()
	for len(samples) >= frameLen {
		f := make([]int16, frameLen)
		copy(f, samples[:frameLen])
		v.queue = append(v.queue, f)
		samples = samples[frameLen:]
	}
	if len(v.queue) > maxQueue {
		v.queue = v.queue[len(v.queue)-maxQueue:]
	}
}

// The primary (newest) Opus payload of an RFC 2198 RED packet.
func redPrimary(p []byte) []byte {
	i, skip := 0, 0
	for i < len(p) {
		if p[i]&0x80 == 0 { // the last header: one byte
			i++
			if i+skip > len(p) {
				return nil
			}
			return p[i+skip:]
		}
		if i+4 > len(p) {
			return nil
		}
		skip += int(binary.BigEndian.Uint16(p[i+2:i+4]) & 0x3ff)
		i += 4
	}
	return nil
}

// ── the party's sounds ──

type tone struct {
	pcm []int16 // 48 kHz stereo
	at  int
	vol float64
}

func playWav(path string, vol float64) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	pcm, err := wavTo48kStereo(data)
	if err != nil {
		return err
	}
	mu.Lock()
	tones = append(tones, &tone{pcm: pcm, vol: vol})
	mu.Unlock()
	startOutput()
	return nil
}

// A 16-bit PCM WAV file as 48 kHz stereo (the rate and layout the output runs at).
func wavTo48kStereo(b []byte) ([]int16, error) {
	if len(b) < 12 || string(b[0:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		return nil, errors.New("not a WAV file")
	}
	var rate, chans, bits int
	var data []byte
	for i := 12; i+8 <= len(b); {
		id, size := string(b[i:i+4]), int(binary.LittleEndian.Uint32(b[i+4:i+8]))
		body := i + 8
		if body+size > len(b) {
			size = len(b) - body
		}
		switch id {
		case "fmt ":
			if size >= 16 {
				chans = int(binary.LittleEndian.Uint16(b[body+2:]))
				rate = int(binary.LittleEndian.Uint32(b[body+4:]))
				bits = int(binary.LittleEndian.Uint16(b[body+14:]))
			}
		case "data":
			data = b[body : body+size]
		}
		i = body + size + size%2
	}
	if bits != 16 || chans < 1 || rate <= 0 || data == nil {
		return nil, errors.New("only 16-bit PCM WAV")
	}
	in := len(data) / 2 / chans
	out := int(int64(in) * sampleRate / int64(rate))
	pcm := make([]int16, out*channels)
	for i := 0; i < out; i++ {
		src := int(int64(i) * int64(rate) / sampleRate)
		if src >= in {
			src = in - 1
		}
		l := int16(binary.LittleEndian.Uint16(data[(src*chans)*2:]))
		r := l
		if chans > 1 {
			r = int16(binary.LittleEndian.Uint16(data[(src*chans+1)*2:]))
		}
		pcm[i*2], pcm[i*2+1] = l, r
	}
	return pcm, nil
}

// ── the mixer ──

var (
	outMu     sync.Mutex
	outActive bool
	outKind   string
)

func outputName() string {
	outMu.Lock()
	defer outMu.Unlock()
	return outKind
}

// Starts the loop that mixes and plays, unless it runs; it stops by itself two seconds after
// there is nothing left to play (no call, no sound), and gives the TV its sound device back.
func startOutput() {
	outMu.Lock()
	if outActive {
		outMu.Unlock()
		return
	}
	outActive = true
	outMu.Unlock()
	go func() {
		defer func() {
			outMu.Lock()
			outActive, outKind = false, ""
			outMu.Unlock()
		}()
		out, kind, err := openOutput(sampleRate, channels)
		if err != nil {
			mu.Lock()
			if state == "on" {
				failure = "no sound output: " + err.Error()
			}
			mu.Unlock()
			return
		}
		defer out.Close()
		outMu.Lock()
		outKind = kind
		outMu.Unlock()
		mix := make([]int16, frameLen)
		acc := make([]int32, frameLen)
		idle := time.Time{}
		for {
			busy := mixFrame(acc, mix)
			if busy {
				idle = time.Time{}
			} else if idle.IsZero() {
				idle = time.Now()
			} else if time.Since(idle) > 2*time.Second {
				return
			}
			if err := out.Write(mix); err != nil {
				return
			}
		}
	}()
}

// One 20 ms frame of everything there is to hear; whether anything is (a call, a sound).
func mixFrame(acc []int32, mix []int16) bool {
	for i := range acc {
		acc[i] = 0
	}
	mu.Lock()
	busy := state == "on" || len(tones) > 0
	if !deafened {
		for _, v := range voices {
			if !v.started {
				if len(v.queue) < prebuffer {
					continue
				}
				v.started = true
			}
			if len(v.queue) == 0 {
				v.started = false // (ran dry: it gathers again before it is heard)
				continue
			}
			f := v.queue[0]
			v.queue = v.queue[1:]
			g, ok := volumes[v.who]
			if !ok {
				g = 1
			}
			for i, s := range f {
				acc[i] += int32(float64(s) * g)
			}
		}
	}
	kept := tones[:0]
	for _, t := range tones {
		for i := 0; i < frameLen && t.at < len(t.pcm); i++ {
			acc[i] += int32(float64(t.pcm[t.at]) * t.vol)
			t.at++
		}
		if t.at < len(t.pcm) {
			kept = append(kept, t)
		}
	}
	tones = kept
	mu.Unlock()
	for i, s := range acc {
		if s > 32767 {
			s = 32767
		} else if s < -32768 {
			s = -32768
		}
		mix[i] = int16(s)
	}
	return busy
}

// ── what the platform side gives (cgo_opus.go and cgo_audio.go; stand-ins in nocgo.go) ──

type decoder interface {
	// Decode decodes one Opus packet (nil: conceal a lost one) into interleaved stereo samples
	// at 48 kHz, and says how many samples per channel it wrote.
	Decode(packet []byte, pcm []int16) (int, error)
	Close()
}

type output interface {
	Write(interleaved []int16) error
	Close()
}
