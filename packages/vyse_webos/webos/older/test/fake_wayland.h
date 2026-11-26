// What wayland_test.c and fake_wayland.c share: Wayland's public types, as vyse_wayland.c
// writes them, and the stand-in library's own few names.
#ifndef VYSE_FAKE_WAYLAND_H_
#define VYSE_FAKE_WAYLAND_H_

#include <stdint.h>

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

// A proxy of the stand-in library: it begins as every real one does.
struct fake_proxy {
  struct wl_object object;
  void (**listener)(void);
  void *data;
};

// The last request the stand-in library was asked to send.
struct fake_sent {
  const char *through;  // which of its calls: "array_flags", "array_constructor", "array"
  struct wl_proxy *proxy;
  uint32_t opcode;
  const struct wl_interface *interface;
  uint32_t version;
  uint32_t flags;
  int count;
  union wl_argument args[20];
};

extern struct fake_sent fake_last;
extern int fake_destroyed;

struct wl_proxy *fake_proxy(const struct wl_interface *interface);
// The compositor saying it has [interface] at [version], numbered [name]; and taking it back.
void fake_offer(struct wl_proxy *registry, uint32_t name, const char *interface, uint32_t version);
void fake_withdraw(struct wl_proxy *registry, uint32_t name);

// What the app calls (vyse_wayland.c's, in the test as in the package)
struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *proxy, uint32_t opcode, const struct wl_interface *interface, uint32_t version,
                                        uint32_t flags, ...);
int wl_proxy_add_listener(struct wl_proxy *proxy, void (**implementation)(void), void *data);

#endif  // VYSE_FAKE_WAYLAND_H_
