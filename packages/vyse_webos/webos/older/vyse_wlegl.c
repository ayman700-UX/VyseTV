// VyseTV on an older webOS: the window LG's embedder draws into, whatever the TV's library
// for it is called.
//
// The embedder asks for "libwayland-egl.so.1". webOS 4.4 has the same four functions in
// "libwayland-egl.so.0", and on some sets they live in the graphics driver itself. In the
// package for older webOS the embedder is pointed at this library instead (build.sh), and
// this passes each call on to wherever the TV has it. See webos/README.md, "Older webOS".

#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>

#define EXPORT __attribute__((visibility("default")))

struct wl_egl_window;
struct wl_surface;

static void *vyse_real(const char *name) {
  static void *lib;
  static int looked;
  if (!looked) {
    looked = 1;
    static const char *const names[] = {"libwayland-egl.so.1", "libwayland-egl.so.0", "libwayland-egl.so", NULL};
    for (int i = 0; names[i] != NULL && lib == NULL; i++) {
      lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    }
    if (lib == NULL) fprintf(stderr, "[vyse] no libwayland-egl on this TV: %s\n", dlerror());
  }
  // (through the library and whatever it needs in turn: on some sets it is a shell over the
  // graphics driver, which is where the functions are)
  void *fn = lib == NULL ? NULL : dlsym(lib, name);
  if (fn == NULL) fprintf(stderr, "[vyse] this TV has no %s\n", name);
  return fn;
}

EXPORT struct wl_egl_window *wl_egl_window_create(struct wl_surface *surface, int width, int height) {
  static struct wl_egl_window *(*real)(struct wl_surface *, int, int);
  if (real == NULL) real = (struct wl_egl_window * (*)(struct wl_surface *, int, int)) vyse_real("wl_egl_window_create");
  return real == NULL ? NULL : real(surface, width, height);
}

EXPORT void wl_egl_window_destroy(struct wl_egl_window *window) {
  static void (*real)(struct wl_egl_window *);
  if (real == NULL) real = (void (*)(struct wl_egl_window *))vyse_real("wl_egl_window_destroy");
  if (real != NULL) real(window);
}

EXPORT void wl_egl_window_resize(struct wl_egl_window *window, int width, int height, int dx, int dy) {
  static void (*real)(struct wl_egl_window *, int, int, int, int);
  if (real == NULL) real = (void (*)(struct wl_egl_window *, int, int, int, int))vyse_real("wl_egl_window_resize");
  if (real != NULL) real(window, width, height, dx, dy);
}

EXPORT void wl_egl_window_get_attached_size(struct wl_egl_window *window, int *width, int *height) {
  static void (*real)(struct wl_egl_window *, int *, int *);
  if (real == NULL) real = (void (*)(struct wl_egl_window *, int *, int *))vyse_real("wl_egl_window_get_attached_size");
  if (real != NULL) {
    real(window, width, height);
  } else {
    if (width != NULL) *width = 0;
    if (height != NULL) *height = 0;
  }
}
