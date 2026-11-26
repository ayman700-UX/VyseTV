// VyseTV on an older webOS: between LG's Flutter embedder and the TV's Wayland library.
//
// The embedder talks to the TV's compositor through libwayland-client. It was built for
// webOS 26, and two things it does there an older TV cannot take:
//
//  * It sends every request with wl_proxy_marshal_flags, which came with Wayland 1.20.
//    webOS 23 and older have Wayland 1.11, where the same requests go through older calls.
//
//  * It asks the compositor for version 2 of "wl_webos_shell", the interface a webOS app gets
//    its window through, whatever version the compositor says it has. Version 2 is from the
//    middle of 2020; the sets before it have version 1, and a compositor asked for more than
//    it has ends the connection there and then: the app would be gone before its first
//    picture. Everything the embedder goes on to use of that interface was already in
//    version 1.
//
// In the package for older webOS the app's program names this library ahead of the TV's own
// (tool/webos/older.sh), so these two functions are the ones the whole app gets:
//
//   wl_proxy_marshal_flags   sends the request through whichever call the TV's library has;
//                            and when the request is "bind to this interface of the
//                            compositor", never with a higher version than the compositor
//                            offered.
//   wl_proxy_add_listener    passed straight on, except for the list of what the compositor
//                            offers (wl_registry): there it notes each interface's version on
//                            the way to whoever listens, which is how the first knows.
//
// On a TV that needs neither (webOS 26) nothing changes: the same requests go out through the
// TV's own call. Wayland's headers are not used: the few types below are the library's
// public, fixed layout. See webos/README.md, "Older webOS".

#define _GNU_SOURCE

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

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

#define VYSE_MARSHAL_FLAG_DESTROY 1u
#define VYSE_MAX_ARGS 20
#define VYSE_REGISTRY_BIND 0u

// ── the TV's own library, as much of it as this TV has ──

typedef void (*vyse_listener)(void);

static struct {
  // Wayland 1.20 and later: one call for every request
  struct wl_proxy *(*array_flags)(struct wl_proxy *, uint32_t, const struct wl_interface *, uint32_t, uint32_t, union wl_argument *);
  // Wayland 1.11: one call for a request that makes an object, one for a request that does not
  struct wl_proxy *(*array_constructor)(struct wl_proxy *, uint32_t, union wl_argument *, const struct wl_interface *, uint32_t);
  void (*array)(struct wl_proxy *, uint32_t, union wl_argument *);
  void (*destroy)(struct wl_proxy *);
  int (*add_listener)(struct wl_proxy *, vyse_listener *, void *);
} tv;

static pthread_once_t vyse_looked = PTHREAD_ONCE_INIT;

static void vyse_look(void) {
  // (the next library after this one that has the name: the TV's libwayland-client)
  tv.array_flags = (struct wl_proxy * (*)(struct wl_proxy *, uint32_t, const struct wl_interface *, uint32_t, uint32_t, union wl_argument *))
      dlsym(RTLD_NEXT, "wl_proxy_marshal_array_flags");
  tv.array_constructor = (struct wl_proxy * (*)(struct wl_proxy *, uint32_t, union wl_argument *, const struct wl_interface *, uint32_t))
      dlsym(RTLD_NEXT, "wl_proxy_marshal_array_constructor_versioned");
  tv.array = (void (*)(struct wl_proxy *, uint32_t, union wl_argument *))dlsym(RTLD_NEXT, "wl_proxy_marshal_array");
  tv.destroy = (void (*)(struct wl_proxy *))dlsym(RTLD_NEXT, "wl_proxy_destroy");
  tv.add_listener = (int (*)(struct wl_proxy *, vyse_listener *, void *))dlsym(RTLD_NEXT, "wl_proxy_add_listener");
  if (tv.add_listener == NULL || (tv.array_flags == NULL && (tv.array_constructor == NULL || tv.array == NULL || tv.destroy == NULL))) {
    fprintf(stderr, "[vyse] the TV's Wayland library lacks what the app sends its requests with\n");
  }
}

// ── what the compositor offers, as each list of it (wl_registry) said ──

#define VYSE_REGISTRIES 32
#define VYSE_OFFERS 160

struct vyse_registry {
  struct wl_proxy *registry;
  vyse_listener *listener;  // whose list this is: {global, global_remove}
  int count;
  struct {
    uint32_t name;
    uint32_t version;
  } offers[VYSE_OFFERS];
};

static pthread_mutex_t vyse_lock = PTHREAD_MUTEX_INITIALIZER;
static struct vyse_registry vyse_registries[VYSE_REGISTRIES];

static int vyse_is_registry(struct wl_proxy *proxy) {
  const struct wl_interface *own = proxy == NULL ? NULL : ((const struct wl_object *)proxy)->interface;
  return own != NULL && own->name != NULL && strcmp(own->name, "wl_registry") == 0;
}

// (with the lock held)
static struct vyse_registry *vyse_find(struct wl_proxy *registry) {
  for (int i = 0; i < VYSE_REGISTRIES; i++) {
    if (vyse_registries[i].registry == registry) return &vyse_registries[i];
  }
  return NULL;
}

// The version the compositor offered of the interface it numbered [name]; 0 when not known.
static uint32_t vyse_offered(struct wl_proxy *registry, uint32_t name) {
  uint32_t version = 0;
  pthread_mutex_lock(&vyse_lock);
  const struct vyse_registry *r = vyse_find(registry);
  if (r != NULL) {
    for (int i = 0; i < r->count; i++) {
      if (r->offers[i].name == name) {
        version = r->offers[i].version;
        break;
      }
    }
  }
  pthread_mutex_unlock(&vyse_lock);
  return version;
}

static void vyse_on_global(void *data, struct wl_proxy *registry, uint32_t name, const char *interface, uint32_t version) {
  vyse_listener *listener = NULL;
  int first = 0;
  pthread_mutex_lock(&vyse_lock);
  struct vyse_registry *r = vyse_find(registry);
  if (r != NULL) {
    listener = r->listener;
    first = r == &vyse_registries[0];
    int at = 0;
    while (at < r->count && r->offers[at].name != name) at++;
    if (at < VYSE_OFFERS) {
      r->offers[at].name = name;
      r->offers[at].version = version;
      if (at == r->count) r->count++;
    }
  }
  pthread_mutex_unlock(&vyse_lock);
  // (for the record of the start: what this TV's compositor has, as the app's first list of
  // it says. Nobody here has an older TV to ask.)
  if (first) fprintf(stderr, "[vyse] the compositor offers %s, version %u\n", interface != NULL ? interface : "?", version);
  if (listener != NULL && listener[0] != NULL) {
    ((void (*)(void *, struct wl_proxy *, uint32_t, const char *, uint32_t))listener[0])(data, registry, name, interface, version);
  }
}

static void vyse_on_global_remove(void *data, struct wl_proxy *registry, uint32_t name) {
  vyse_listener *listener = NULL;
  pthread_mutex_lock(&vyse_lock);
  struct vyse_registry *r = vyse_find(registry);
  if (r != NULL) {
    listener = r->listener;
    for (int i = 0; i < r->count; i++) {
      if (r->offers[i].name == name) {
        r->offers[i] = r->offers[--r->count];
        break;
      }
    }
  }
  pthread_mutex_unlock(&vyse_lock);
  if (listener != NULL && listener[1] != NULL) {
    ((void (*)(void *, struct wl_proxy *, uint32_t))listener[1])(data, registry, name);
  }
}

static vyse_listener vyse_registry_listener[2] = {(vyse_listener)vyse_on_global, (vyse_listener)vyse_on_global_remove};

// A listener is set on [proxy]. Only for a wl_registry is anything done: this library's two
// functions go in its place and call the real ones, with the same data, after taking note.
EXPORT int wl_proxy_add_listener(struct wl_proxy *proxy, vyse_listener *implementation, void *data) {
  pthread_once(&vyse_looked, vyse_look);
  if (tv.add_listener == NULL) return -1;
  if (implementation == NULL || !vyse_is_registry(proxy)) return tv.add_listener(proxy, implementation, data);

  // (the lock is held across the two steps: an offer that arrives in between, on another
  // thread, waits for it and finds whose list this is)
  pthread_mutex_lock(&vyse_lock);
  struct vyse_registry *r = vyse_find(proxy);
  if (r == NULL) r = vyse_find(NULL);
  if (r == NULL) {
    // (no room to keep another list: it is listened to as it would be without this library)
    pthread_mutex_unlock(&vyse_lock);
    return tv.add_listener(proxy, implementation, data);
  }
  const int result = tv.add_listener(proxy, vyse_registry_listener, data);
  if (result == 0) {
    // (a registry at an address seen before is a new one in a freed one's place; one that
    // was refused a second listener keeps its first, and its list)
    r->registry = proxy;
    r->listener = implementation;
    r->count = 0;
  }
  pthread_mutex_unlock(&vyse_lock);
  return result;
}

// Sends request [opcode] on [proxy]. With [interface] the request makes a new object of that
// kind, of that [version], which is returned; with the destroy flag the proxy is let go
// afterwards.
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
  // about the one that follows them). As libwayland's own wl_argument_from_va_list reads them.
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

  // wl_registry.bind(name, interface, version, new id): no higher than the compositor has.
  if (interface != NULL && opcode == VYSE_REGISTRY_BIND && strcmp(signature, "usun") == 0 && vyse_is_registry(proxy)) {
    const uint32_t offered = vyse_offered(proxy, args[0].u);
    if (offered != 0 && offered < version) {
      fprintf(stderr, "[vyse] %s: this TV's compositor has version %u of it, the app asked for %u and is given %u\n",
              interface->name != NULL ? interface->name : "?", offered, version, offered);
      version = offered;
      args[2].u = offered;
    }
  }

  pthread_once(&vyse_looked, vyse_look);
  if (tv.array_flags != NULL) return tv.array_flags(proxy, opcode, interface, version, flags, args);

  struct wl_proxy *made = NULL;
  if (interface != NULL) {
    if (tv.array_constructor != NULL) made = tv.array_constructor(proxy, opcode, args, interface, version);
  } else if (tv.array != NULL) {
    tv.array(proxy, opcode, args);
  }
  if ((flags & VYSE_MARSHAL_FLAG_DESTROY) != 0 && tv.destroy != NULL) tv.destroy(proxy);
  return made;
}
