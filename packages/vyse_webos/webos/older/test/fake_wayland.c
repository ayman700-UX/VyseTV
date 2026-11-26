// A stand-in for the TV's libwayland-client, for trying vyse_wayland.c without a TV
// (wayland_test.c). It keeps what it was last asked to send, and lets the test play the
// compositor: say what it offers. Built twice: as an older TV's library (Wayland 1.11, the
// two older calls) and, with VYSE_FAKE_NEW, as a newer one's (the one call of Wayland 1.20).

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fake_wayland.h"

struct fake_sent fake_last;
int fake_destroyed;

static void fake_keep(const char *through, struct wl_proxy *proxy, uint32_t opcode, const struct wl_interface *interface, uint32_t version,
                      uint32_t flags, const union wl_argument *args) {
  memset(&fake_last, 0, sizeof fake_last);
  fake_last.through = through;
  fake_last.proxy = proxy;
  fake_last.opcode = opcode;
  fake_last.interface = interface;
  fake_last.version = version;
  fake_last.flags = flags;
  const char *signature = ((struct wl_object *)proxy)->interface->methods[opcode].signature;
  int count = 0;
  for (const char *c = signature; *c != '\0'; c++) {
    if (strchr("iufsonah", *c) == NULL) continue;
    fake_last.args[count] = args[count];
    count++;
  }
  fake_last.count = count;
}

struct wl_proxy *fake_proxy(const struct wl_interface *interface) {
  struct fake_proxy *p = calloc(1, sizeof *p);
  p->object.interface = interface;
  return (struct wl_proxy *)p;
}

void fake_offer(struct wl_proxy *registry, uint32_t name, const char *interface, uint32_t version) {
  struct fake_proxy *p = (struct fake_proxy *)registry;
  if (p->listener == NULL || p->listener[0] == NULL) return;
  ((void (*)(void *, struct wl_proxy *, uint32_t, const char *, uint32_t))p->listener[0])(p->data, registry, name, interface, version);
}

void fake_withdraw(struct wl_proxy *registry, uint32_t name) {
  struct fake_proxy *p = (struct fake_proxy *)registry;
  if (p->listener == NULL || p->listener[1] == NULL) return;
  ((void (*)(void *, struct wl_proxy *, uint32_t))p->listener[1])(p->data, registry, name);
}

int wl_proxy_add_listener(struct wl_proxy *proxy, void (**implementation)(void), void *data) {
  struct fake_proxy *p = (struct fake_proxy *)proxy;
  if (p->listener != NULL) return -1;
  p->listener = implementation;
  p->data = data;
  return 0;
}

void wl_proxy_destroy(struct wl_proxy *proxy) {
  (void)proxy;
  fake_destroyed++;
}

#ifdef VYSE_FAKE_NEW
struct wl_proxy *wl_proxy_marshal_array_flags(struct wl_proxy *proxy, uint32_t opcode, const struct wl_interface *interface, uint32_t version,
                                              uint32_t flags, union wl_argument *args) {
  fake_keep("array_flags", proxy, opcode, interface, version, flags, args);
  if ((flags & 1u) != 0) fake_destroyed++;
  return interface != NULL ? fake_proxy(interface) : NULL;
}
#endif

struct wl_proxy *wl_proxy_marshal_array_constructor_versioned(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args,
                                                              const struct wl_interface *interface, uint32_t version) {
  fake_keep("array_constructor", proxy, opcode, interface, version, 0, args);
  return fake_proxy(interface);
}

void wl_proxy_marshal_array(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args) {
  fake_keep("array", proxy, opcode, NULL, 0, 0, args);
}
