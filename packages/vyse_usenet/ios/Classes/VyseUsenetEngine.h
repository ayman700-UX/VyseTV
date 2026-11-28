// The C entry points of the iPhone and Apple TV engine library (packages/vyse_usenet/apple):
// the Usenet engine and the torrent engine in one Go program, linked into the app from
// VyseUsenet-ios.xcframework (iPhone/iPad) or VyseUsenet-tvos.xcframework (Apple TV). One
// program, so the app holds one Go runtime (two crashed the 1.0.4 Apple TV app at launch).
// Declared here so Swift can call them: on iPhone through this pod's own module (the torrent
// plugin's pod imports it), on Apple TV through tvos/Runner/Runner-Bridging-Header.h.
#ifndef VYSE_USENET_ENGINE_H
#define VYSE_USENET_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

// ── The Usenet engine (packages/vyse_usenet/engine/capi) ──

// Starts the engine with its bootstrap record (JSON) and answers its port on 127.0.0.1, or -1.
int VyseUsenetStart(char *bootstrap);
// Closes every session and stops serving.
void VyseUsenetStop(void);
// Why the last start failed, or NULL. Owned by the engine.
char *VyseUsenetError(void);

// ── The torrent engine (TorrServer, packages/torrserver_flutter/tool/go-shim) ──

// Starts it on [port] with its files in [dataDir]; an empty [ip] listens on every address.
// NULL, or why it did not start (free it with TorrServerFree).
char *TorrServerStart(int port, char *dataDir, char *ip);
// Stops it: NULL, or why not (free it with TorrServerFree).
char *TorrServerStop(void);
// 1 while it runs.
int TorrServerIsRunning(void);
// Frees a string the two above handed back.
void TorrServerFree(char *p);

#ifdef __cplusplus
}
#endif

#endif
