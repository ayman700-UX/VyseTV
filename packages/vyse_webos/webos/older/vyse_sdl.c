// VyseTV on an older webOS: what the TV's media library is told when it asks SDL for a window.
//
// Before webOS 26 the media library (NDL) has no way to be handed the window a video goes in.
// When the app starts a player (NDL_MediaInit) the library looks for SDL instead
// (libSDL2-2.0.so.0, which LG's own native apps are made with) and asks it for the app's window
// and for the id of a window "exported" from it, the one the video plane shows in. VyseTV has
// no SDL window: the TV's SDL answers nothing, and the library goes on with nothing. Any video
// or song played there ended the app at once (an LG webOS 5.6 tester, 2026-11-27: "App closes
// when playing any media").
//
// This library is VyseTV's SDL as far as the media library is concerned. It carries SDL's
// name (libSDL2-2.0.so.0) and is a library the app's program needs (tool/webos/older.sh), so it
// is loaded at the start, before the media library, and when that library asks for SDL by that
// name it is given this one. (Loaded just before the first player instead, it came too late on
// webOS 6 to 25, where the first media call loads the media library and the TV's SDL with it.)
// It answers the few calls the media library makes:
//
//   * the window: a stand-in (the media library only checks there is one);
//   * the exported window's id: the one the app made for the picture (the native side says
//     which, with VyseSdlUseWindow, before each start and each load), or for sound alone a
//     placeholder, since sound needs no window;
//   * placing, naming and removing that window: nothing to do, the app's own embedder places
//     it, so they are said yes to.
//
// Every call is written to the start log (vyse_start.c), so a tester's log says what this
// TV's media library asked for. On webOS 26 the media library takes the window directly and
// never asks: the library is in the package and not loaded.
//
// The idea and the list of calls follow an open project that runs LG's Flutter apps on older
// webOS (BSD-3-Clause, tested on webOS 6.5).

#define _GNU_SOURCE

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

// (a window id is a short name the compositor made up, "_Window_Id_3" and the like)
static char vyse_window[256];

// For a player of sound alone: a name for a window that is never shown.
#define VYSE_NO_WINDOW "_vyse_sound_only_"

// The window the next player started or loaded is to show its picture in; "" or NULL: none
// (sound alone). Called by the player's native side (vyse_webos_plugin.cc).
EXPORT void VyseSdlUseWindow(const char *id) {
  if (id != NULL && id[0] != '\0') {
    strncpy(vyse_window, id, sizeof vyse_window - 1);
    vyse_window[sizeof vyse_window - 1] = '\0';
  } else {
    vyse_window[0] = '\0';
  }
  fprintf(stderr, "[vyse] media: the next player shows its picture in %s\n", vyse_window[0] != '\0' ? vyse_window : "no window (sound alone)");
}

// ── SDL, as much of it as the media library asks for ──

typedef struct {
  int x, y, w, h;
} vyse_rect;

// Any address that is not null stands for "the app's window".
static int vyse_fake_window;

EXPORT void *SDL_GL_GetCurrentWindow(void) {
  fprintf(stderr, "[vyse] media asked SDL: the current window\n");
  return &vyse_fake_window;
}

EXPORT void *SDL_GetWindowFromID(uint32_t id) {
  fprintf(stderr, "[vyse] media asked SDL: window %u\n", id);
  return &vyse_fake_window;
}

EXPORT void SDL_GetWindowSize(void *window, int *w, int *h) {
  (void)window;
  if (w != NULL) *w = 1920;
  if (h != NULL) *h = 1080;
}

EXPORT const char *SDL_GetError(void) { return ""; }

// The id of the window the video plane shows in. (SDL hands back a string the caller frees.)
EXPORT const char *SDL_webOSCreateExportedWindow(int type) {
  const char *id = vyse_window[0] != '\0' ? vyse_window : VYSE_NO_WINDOW;
  fprintf(stderr, "[vyse] media asked SDL: an exported window (type %d), given %s\n", type, id);
  return strdup(id);
}

EXPORT int SDL_webOSSetExportedWindow(const char *id, vyse_rect *src, vyse_rect *dst) {
  (void)src;
  if (dst != NULL) {
    fprintf(stderr, "[vyse] media asked SDL: place %s at %d,%d %dx%d (left to the app)\n", id != NULL ? id : "", dst->x, dst->y, dst->w, dst->h);
  }
  return 1;  // SDL_TRUE
}

EXPORT int SDL_webOSExportedSetProperty(const char *id, const char *name, const char *value) {
  fprintf(stderr, "[vyse] media asked SDL: %s's %s = %s (left to the app)\n", id != NULL ? id : "", name != NULL ? name : "", value != NULL ? value : "");
  return 1;
}

// The rest of the TV's SDL calls for an exported window and the screen: said yes to, so a call
// the list above did not foresee is answered instead of ending the app. (The window is the
// app's embedder's to place.)
EXPORT int SDL_webOSExportedSetCropRegion(const char *id, vyse_rect *org, vyse_rect *src, vyse_rect *dst) {
  (void)org;
  (void)src;
  (void)dst;
  fprintf(stderr, "[vyse] media asked SDL: crop %s (left to the app)\n", id != NULL ? id : "");
  return 1;
}

EXPORT int SDL_webOSGetPanelResolution(int *width, int *height) {
  fprintf(stderr, "[vyse] media asked SDL: the panel's size\n");
  if (width != NULL) *width = 1920;
  if (height != NULL) *height = 1080;
  return 1;
}

EXPORT int SDL_webOSGetRefreshRate(int *rate) {
  fprintf(stderr, "[vyse] media asked SDL: the refresh rate\n");
  if (rate != NULL) *rate = 60;
  return 1;
}

EXPORT void SDL_webOSDestroyExportedWindow(const char *id) {
  fprintf(stderr, "[vyse] media asked SDL: remove %s (left to the app)\n", id != NULL ? id : "");
}
