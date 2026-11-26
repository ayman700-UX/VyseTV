//go:build !cgo

// Stand-ins so the Go logic builds without a C compiler (a check on a PC: CGO_ENABLED=0 go vet).
// The library itself is always built with cgo (build.sh).
package main

import "errors"

func newDecoder() (decoder, error) { return nil, errors.New("built without cgo") }

func openOutput(rate, channels int) (output, string, error) {
	return nil, "", errors.New("built without cgo")
}
