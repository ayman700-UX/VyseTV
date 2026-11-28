// The Usenet engine's C entry points (engine/cmd/libvyse-usenet), linked into the app from
// VyseUsenet-ios.xcframework (iPhone/iPad) or VyseUsenet-tvos.xcframework (Apple TV).
// Declared here so Swift can call them: on iPhone through this pod's own module, on Apple TV
// through tvos/Runner/Runner-Bridging-Header.h.
#ifndef VYSE_USENET_ENGINE_H
#define VYSE_USENET_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

// Starts the engine with its bootstrap record (JSON) and answers its port on 127.0.0.1, or -1.
int VyseUsenetStart(char *bootstrap);
// Closes every session and stops serving.
void VyseUsenetStop(void);
// Why the last start failed, or NULL. Owned by the engine.
char *VyseUsenetError(void);

#ifdef __cplusplus
}
#endif

#endif
