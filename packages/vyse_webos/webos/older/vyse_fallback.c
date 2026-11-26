// VyseTV on an older webOS: what a newer webOS has in its own libraries and an older one lacks.
//
// LG's Flutter embedder is built for webOS 26 and asks the TV for a few things an older TV
// does not have. This library has them. It is arranged to be the very last place the loader
// looks (it is needed only by another stand-in, which is itself needed only by LG's embedder),
// so on a TV that has the real thing the real thing is found first and nothing here is used.
// See webos/README.md, "Older webOS".
//
//  * wl_proxy_marshal_flags: how every request to the compositor is sent by code generated
//    for Wayland 1.20 and later. webOS 23 and older have Wayland 1.11, which sends the same
//    requests through two older calls. This is the newer call written with the older ones.
//
//  * wl_webos_foreign_interface, wl_webos_exported_interface: the description of "exported
//    windows", the way a TV puts a window of its video plane under an app. webOS 4 does not
//    have the feature, so its library does not have the description. LG's embedder names it
//    whether it is used or not; here it is, so the embedder loads. Nothing will ever be sent
//    with it on such a TV: its compositor never offers the feature, and the app is told so
//    (the "capabilities" of packages/vyse_webos) and places the picture another way.
//
// Wayland's own headers are not used: the few types below are the library's public, fixed
// layout, and writing them here keeps this file free of which Wayland the build machine has.

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#define EXPORT __attribute__((visibility("default")))

struct wl_interface;
struct wl_proxy;
struct wl_array;

struct wl_message {
  const char *name;
  const char *signature;
  const struct wl_interface **types;
};

struct wl_interface {
  const char *name;
  int version;
  int method_count;
  const struct wl_message *methods;
  int event_count;
  const struct wl_message *events;
};

// (what every proxy begins with)
struct wl_object {
  const struct wl_interface *interface;
  const void *implementation;
  uint32_t id;
};

union wl_argument {
  int32_t i;
  uint32_t u;
  int32_t f;
  const char *s;
  struct wl_object *o;
  uint32_t n;
  struct wl_array *a;
  int32_t h;
};

// libwayland-client, as old as 1.11
extern struct wl_proxy *wl_proxy_marshal_array_constructor_versioned(
    struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args,
    const struct wl_interface *interface, uint32_t version);
extern void wl_proxy_marshal_array(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args);
extern void wl_proxy_destroy(struct wl_proxy *proxy);
extern const struct wl_interface wl_surface_interface;
extern const struct wl_interface wl_region_interface;

#define VYSE_MARSHAL_FLAG_DESTROY 1u
#define VYSE_MAX_ARGS 20

// The one name of this library that another stand-in uses (vyse_sdevent.c, at its start):
// a library nothing uses a name of is left off the list of what must be loaded by a build
// set to keep only what is used, which LG's is, and then nothing here would ever be found.
EXPORT int vyse_fallback_present(void) { return 1; }

// Sends request [opcode] on [proxy]. With [interface] the request makes a new object of that
// kind, which is returned; with the destroy flag the proxy is let go afterwards.
EXPORT struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *proxy, uint32_t opcode,
                                                const struct wl_interface *interface,
                                                uint32_t version, uint32_t flags, ...) {
  union wl_argument args[VYSE_MAX_ARGS];
  const struct wl_interface *own = ((const struct wl_object *)proxy)->interface;
  const char *signature = own->methods[opcode].signature;
  int count = 0;
  va_list ap;
  va_start(ap, flags);
  // The arguments, by the request's signature (a letter each; "?" and digits say other things
  // about the one that follows them).
  for (const char *c = signature; *c != '\0' && count < VYSE_MAX_ARGS; c++) {
    switch (*c) {
      case 'i':
        args[count++].i = va_arg(ap, int32_t);
        break;
      case 'u':
        args[count++].u = va_arg(ap, uint32_t);
        break;
      case 'f':
        args[count++].f = va_arg(ap, int32_t);
        break;
      case 's':
        args[count++].s = va_arg(ap, const char *);
        break;
      case 'o':
      case 'n':
        args[count++].o = va_arg(ap, struct wl_object *);
        break;
      case 'a':
        args[count++].a = va_arg(ap, struct wl_array *);
        break;
      case 'h':
        args[count++].h = va_arg(ap, int32_t);
        break;
      default:
        break;
    }
  }
  va_end(ap);

  struct wl_proxy *made = NULL;
  if (interface != NULL) {
    made = wl_proxy_marshal_array_constructor_versioned(proxy, opcode, args, interface, version);
  } else {
    wl_proxy_marshal_array(proxy, opcode, args);
  }
  if ((flags & VYSE_MARSHAL_FLAG_DESTROY) != 0) wl_proxy_destroy(proxy);
  return made;
}

// ── exported windows, as webos-foreign.xml describes them (webOS's own Wayland extension) ──

static const struct wl_interface vyse_imported_interface = {"wl_webos_imported", 2, 0, NULL, 0, NULL};

EXPORT extern const struct wl_interface wl_webos_exported_interface;

static const struct wl_interface *vyse_foreign_types[] = {
    // export_element(new wl_webos_exported, wl_surface, uint)
    &wl_webos_exported_interface, &wl_surface_interface, NULL,
    // import_element(new wl_webos_imported, string, uint)
    &vyse_imported_interface, NULL, NULL,
};

static const struct wl_message vyse_foreign_requests[] = {
    {"destroy", "", vyse_foreign_types + 2},
    {"export_element", "nou", vyse_foreign_types + 0},
    {"import_element", "nsu", vyse_foreign_types + 3},
};

EXPORT const struct wl_interface wl_webos_foreign_interface = {
    "wl_webos_foreign", 1, 3, vyse_foreign_requests, 0, NULL,
};

static const struct wl_interface *vyse_exported_types[] = {
    &wl_region_interface, &wl_region_interface, &wl_region_interface, NULL, NULL,
};

static const struct wl_message vyse_exported_requests[] = {
    {"destroy", "", vyse_exported_types + 3},
    {"set_exported_window", "oo", vyse_exported_types + 0},
    {"set_crop_region", "2ooo", vyse_exported_types + 0},
    {"set_property", "2ss", vyse_exported_types + 3},
};

static const struct wl_message vyse_exported_events[] = {
    {"window_id_assigned", "su", vyse_exported_types + 3},
};

EXPORT const struct wl_interface wl_webos_exported_interface = {
    "wl_webos_exported", 2, 4, vyse_exported_requests, 1, vyse_exported_events,
};
