// The engine inside the app's own process, for the platforms where an app may not start a
// program of its own: iPhone/iPad and Apple TV (a static library, -buildmode=c-archive) and
// Samsung TVs (a shared library, -buildmode=c-shared). It serves exactly what cmd/vyse-usenet
// serves, on 127.0.0.1 and a port of its own; only the start differs: the bootstrap record the
// program reads from stdin is handed to VyseUsenetStart instead, and VyseUsenetStop takes the
// place of stdin closing.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"runtime/debug"
	"sync"
	"time"
	"unsafe"

	"vyse/usenet/internal/engine"
)

type running struct {
	cancel context.CancelFunc
	app    *engine.Server
	srv    *http.Server
	port   int
}

var (
	mu      sync.Mutex
	current *running
	lastErr *C.char
)

func setError(err error) {
	if lastErr != nil {
		C.free(unsafe.Pointer(lastErr))
		lastErr = nil
	}
	if err != nil {
		lastErr = C.CString(err.Error())
	}
}

// VyseUsenetStart starts the engine with a bootstrap record (JSON: token, certificates,
// memoryMiB, nzbCacheDir, as cmd/vyse-usenet reads from stdin) and answers its port, or -1
// (VyseUsenetError says why). A second start while one runs answers the running one's port.
//
//export VyseUsenetStart
func VyseUsenetStart(bootstrap *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()
	if current != nil {
		return C.int(current.port)
	}
	port, err := start([]byte(C.GoString(bootstrap)))
	setError(err)
	if err != nil {
		return -1
	}
	return C.int(port)
}

// VyseUsenetStop closes every session and stops serving. Starting again afterwards is allowed.
//
//export VyseUsenetStop
func VyseUsenetStop() {
	mu.Lock()
	defer mu.Unlock()
	if current == nil {
		return
	}
	current.cancel()
	_ = current.srv.Close()
	current.app.Close()
	current = nil
}

// VyseUsenetError is why the last VyseUsenetStart failed, or NULL. The string stays valid
// until the next start.
//
//export VyseUsenetError
func VyseUsenetError() *C.char { return lastErr }

func start(raw []byte) (int, error) {
	var init struct {
		Token        string   `json:"token"`
		Certificates []string `json:"certificates"`
		MemoryMiB    int64    `json:"memoryMiB"`
		NZBCacheDir  string   `json:"nzbCacheDir"`
	}
	if err := json.Unmarshal(raw, &init); err != nil {
		return 0, err
	}
	if len(init.Token) < 32 {
		return 0, errors.New("the control token is too short")
	}
	limit := init.MemoryMiB
	if limit < 64 {
		limit = 128
	}
	if limit > 512 {
		limit = 512
	}
	// (inside an app the limit covers the app's Go heap as well, which is only this engine)
	debug.SetMemoryLimit(limit << 20)
	roots, _ := x509.SystemCertPool()
	if roots == nil {
		roots = x509.NewCertPool()
	}
	for _, pem := range init.Certificates {
		roots.AppendCertsFromPEM([]byte(pem))
	}
	ctx, cancel := context.WithCancel(context.Background())
	transport := &http.Transport{Proxy: http.ProxyFromEnvironment, TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}, ResponseHeaderTimeout: 30 * time.Second, IdleConnTimeout: 60 * time.Second}
	client := &http.Client{Transport: transport, Timeout: 2 * time.Minute}
	app := engine.NewServer(ctx, init.Token, roots, client)
	app.SetNZBCacheDir(init.NZBCacheDir)
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		cancel()
		app.Close()
		return 0, err
	}
	srv := &http.Server{Handler: app, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 << 10, BaseContext: func(net.Listener) context.Context { return ctx }}
	port := ln.Addr().(*net.TCPAddr).Port
	current = &running{cancel: cancel, app: app, srv: srv, port: port}
	go func() { _ = srv.Serve(ln) }()
	return port, nil
}

func main() {}
