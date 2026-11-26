// VyseTV on an older webOS: what a newer webOS has in its own libraries and an older one lacks.
//
// LG's Flutter embedder is built for webOS 26 and names two things of the TV's Wayland
// extension library that a 2018 or 2019 set does not have. This library has them. It is
// arranged to be the very last place the loader looks (it is needed only by another stand-in,
// which is itself needed only by LG's embedder), so on a TV that has the real thing the real
// thing is found first and nothing here is used. See webos/README.md, "Older webOS".
//
//  * wl_webos_foreign_interface, wl_webos_exported_interface: the description of "exported
//    windows", the way a TV puts a window of its video plane under an app. webOS 4 does not
//    have the feature, so its library does not have the description. LG's embedder names it
//    whether it is used or not; here it is, so the embedder loads. Nothing will ever be sent
//    with it on such a TV: its compositor never offers the feature, and the app is told so
//    (the "capabilities" of packages/vyse_webos) and places the picture another way.
//
// (The call every request is sent with, which an older Wayland library also lacks, is in
// vyse_wayland.c: that one has to come first, not last.)
//
// Wayland's own headers are not used: the few types below are the library's public, fixed
// layout, and writing them here keeps this file free of which Wayland the build machine has.

#include <stddef.h>
#include <stdint.h>

#define EXPORT __attribute__((visibility("default")))

struct wl_interface;

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

// libwayland-client's own
extern const struct wl_interface wl_surface_interface;
extern const struct wl_interface wl_region_interface;

// The one name of this library that another stand-in uses (vyse_sdevent.c, at its start):
// a library nothing uses a name of is left off the list of what must be loaded by a build
// set to keep only what is used, which LG's is, and then nothing here would ever be found.
EXPORT int vyse_fallback_present(void) { return 1; }

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
