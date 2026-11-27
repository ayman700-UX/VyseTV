// Tries vyse_wayland.c without a TV: this program plays the app (it listens to what the
// compositor offers, binds, sends requests) and, through the stand-in library, the compositor
// and the TV's Wayland library. tool/webos/older.sh runs it in an emulator as the package is
// made, once against an older TV's shape of that library and once against a newer one's
// ("old" or "new" as the one argument), with the very libvyse_wayland.so that is packaged.
//
// It says each thing it checked, and ends with 1 if any did not hold.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "fake_wayland.h"

static int failed;

#define CHECK(what, holds)                                         \
  do {                                                             \
    if (holds) {                                                   \
      printf("     ok    %s\n", what);                             \
    } else {                                                       \
      printf("     WRONG %s (wayland_test.c:%d)\n", what, __LINE__); \
      failed = 1;                                                  \
    }                                                              \
  } while (0)

// wl_registry as Wayland has it: its first request is bind(name, interface, version, new id).
static const struct wl_message registry_requests[] = {{"bind", "usun", NULL}};
static const struct wl_interface registry_interface = {"wl_registry", 1, 1, registry_requests, 0, NULL};

// An interface made up for this test, with a request of every kind of argument.
static const struct wl_message thing_requests[] = {
    {"destroy", "", NULL},
    {"mixed", "2iuf?so?oah", NULL},
    {"make", "no", NULL},
};
static const struct wl_interface thing_interface = {"vyse_thing", 3, 3, thing_requests, 0, NULL};

static const struct wl_interface shell_interface = {"wl_webos_shell", 2, 0, NULL, 0, NULL};

// A seat and its pointer, as Wayland has them: a seat's first request makes its pointer.
static const struct wl_message seat_requests[] = {{"get_pointer", "n", NULL}};
static const struct wl_interface seat_interface = {"wl_seat", 5, 1, seat_requests, 0, NULL};
static const struct wl_interface pointer_interface = {"wl_pointer", 5, 0, NULL, 0, NULL};

// What the app heard from the compositor.
static struct {
  int offers;
  int withdrawn;
  void *data;
  uint32_t name;
  uint32_t version;
  char interface[64];
} heard;

static void on_offer(void *data, struct wl_proxy *registry, uint32_t name, const char *interface, uint32_t version) {
  (void)registry;
  heard.offers++;
  heard.data = data;
  heard.name = name;
  heard.version = version;
  snprintf(heard.interface, sizeof heard.interface, "%s", interface);
}

static void on_withdrawn(void *data, struct wl_proxy *registry, uint32_t name) {
  (void)registry;
  heard.withdrawn++;
  heard.data = data;
  heard.name = name;
}

static void on_nothing(void) {}

static void (*registry_listener[2])(void) = {(void (*)(void))on_offer, (void (*)(void))on_withdrawn};
static void (*plain_listener[1])(void) = {on_nothing};

int main(int argc, char **argv) {
  const int new_tv = argc > 1 && strcmp(argv[1], "new") == 0;
  const char *makes = new_tv ? "array_flags" : "array_constructor";
  const char *sends = new_tv ? "array_flags" : "array";
  int mine = 7;

  struct wl_proxy *registry = fake_proxy(&registry_interface);
  CHECK("a listener is set on the list of what the compositor offers", wl_proxy_add_listener(registry, registry_listener, &mine) == 0);
  CHECK("  and the app's own data stays with that list", ((struct fake_proxy *)registry)->data == &mine);
  CHECK("  and a second listener is refused, as the TV's library refuses it", wl_proxy_add_listener(registry, registry_listener, &mine) == -1);

  fake_offer(registry, 11, "wl_compositor", 3);
  fake_offer(registry, 12, "wl_webos_shell", 1);
  fake_offer(registry, 13, "wl_webos_foreign", 1);
  CHECK("the app hears each offer, as it was made",
        heard.offers == 3 && heard.data == &mine && heard.name == 13 && heard.version == 1 && strcmp(heard.interface, "wl_webos_foreign") == 0);

  // The case this is all for: version 2 of the shell asked of a compositor that has 1.
  struct wl_proxy *shell = wl_proxy_marshal_flags(registry, 0, &shell_interface, 2, 0, 12u, shell_interface.name, 2u, NULL);
  CHECK("binding asks for no more than the compositor has", shell != NULL && fake_last.version == 1 && fake_last.args[2].u == 1);
  CHECK("  with the rest of the request as the app sent it",
        fake_last.proxy == registry && fake_last.opcode == 0 && fake_last.interface == &shell_interface && fake_last.count == 4 &&
            fake_last.args[0].u == 12 && fake_last.args[1].s == shell_interface.name && fake_last.args[3].o == NULL);
  CHECK("  through the call this TV's library has", strcmp(fake_last.through, makes) == 0);

  wl_proxy_marshal_flags(registry, 0, &thing_interface, 2, 0, 11u, "wl_compositor", 2u, NULL);
  CHECK("a version the compositor has is asked for as it is", fake_last.version == 2 && fake_last.args[2].u == 2 && fake_last.args[0].u == 11);
  wl_proxy_marshal_flags(registry, 0, &thing_interface, 3, 0, 11u, "wl_compositor", 3u, NULL);
  CHECK("  the highest it has too", fake_last.version == 3 && fake_last.args[2].u == 3);
  wl_proxy_marshal_flags(registry, 0, &thing_interface, 4, 0, 99u, "vyse_thing", 4u, NULL);
  CHECK("an interface never offered is asked for as the app asked", fake_last.version == 4 && fake_last.args[2].u == 4);

  fake_withdraw(registry, 12);
  CHECK("the app hears an offer taken back", heard.withdrawn == 1 && heard.name == 12 && heard.data == &mine);
  wl_proxy_marshal_flags(registry, 0, &shell_interface, 2, 0, 12u, shell_interface.name, 2u, NULL);
  CHECK("  and what is no longer offered is held against nothing", fake_last.version == 2 && fake_last.args[2].u == 2);
  fake_offer(registry, 12, "wl_webos_shell", 2);
  wl_proxy_marshal_flags(registry, 0, &shell_interface, 2, 0, 12u, shell_interface.name, 2u, NULL);
  CHECK("  nor is an older offer, once a newer one is made", fake_last.version == 2);

  // A second list of offers keeps its own numbers.
  struct wl_proxy *second = fake_proxy(&registry_interface);
  wl_proxy_add_listener(second, registry_listener, &mine);
  fake_offer(second, 12, "something_else", 5);
  wl_proxy_marshal_flags(second, 0, &thing_interface, 9, 0, 12u, "something_else", 9u, NULL);
  CHECK("each list of offers is kept apart", fake_last.version == 5 && fake_last.args[2].u == 5 && fake_last.proxy == second);
  wl_proxy_marshal_flags(registry, 0, &shell_interface, 2, 0, 12u, shell_interface.name, 2u, NULL);
  CHECK("  both ways", fake_last.version == 2);

  // Everything else goes through as it is.
  struct wl_proxy *thing = fake_proxy(&thing_interface);
  struct wl_proxy *other = fake_proxy(&thing_interface);
  struct wl_array *array = (struct wl_array *)&heard;
  static const char text[] = "text";
  wl_proxy_marshal_flags(thing, 1, NULL, 3, 0, -5, 4000000000u, 768, text, other, NULL, array, 9);
  CHECK("a request's arguments arrive each as it was given",
        fake_last.count == 8 && fake_last.args[0].i == -5 && fake_last.args[1].u == 4000000000u && fake_last.args[2].f == 768 &&
            fake_last.args[3].s == text && fake_last.args[4].o == (struct wl_object *)other && fake_last.args[5].o == NULL &&
            fake_last.args[6].a == array && fake_last.args[7].h == 9);
  CHECK("  on the object it was sent on, through the call this TV's library has",
        fake_last.proxy == thing && fake_last.opcode == 1 && fake_last.interface == NULL && strcmp(fake_last.through, sends) == 0);

  struct wl_proxy *made = wl_proxy_marshal_flags(thing, 2, &thing_interface, 3, 0, NULL, other);
  CHECK("a request that makes an object gives the object back",
        made != NULL && ((struct wl_object *)made)->interface == &thing_interface && fake_last.version == 3 && fake_last.count == 2 &&
            fake_last.args[0].o == NULL && fake_last.args[1].o == (struct wl_object *)other && strcmp(fake_last.through, makes) == 0);

  const int before = fake_destroyed;
  wl_proxy_marshal_flags(other, 0, NULL, 3, 1u);
  CHECK("a request that ends its object lets the object go, once", fake_destroyed == before + 1 && fake_last.proxy == other && fake_last.opcode == 0);
  wl_proxy_marshal_flags(thing, 1, NULL, 3, 0, 1, 2u, 3, text, NULL, NULL, array, 4);
  CHECK("  and one that does not, does not", fake_destroyed == before + 1);

  CHECK("a listener on anything else is set as it is",
        wl_proxy_add_listener(thing, plain_listener, &mine) == 0 && ((struct fake_proxy *)thing)->listener == plain_listener &&
            ((struct fake_proxy *)thing)->data == &mine);

  // The Magic Remote: the embedder makes a pointer on every seat and listens to the first.
  struct wl_proxy *seat_a = fake_proxy(&seat_interface);
  struct wl_proxy *seat_b = fake_proxy(&seat_interface);
  struct wl_proxy *pointer_a = wl_proxy_marshal_flags(seat_a, 0, &pointer_interface, 5, 0, NULL);
  struct wl_proxy *pointer_b = wl_proxy_marshal_flags(seat_b, 0, &pointer_interface, 5, 0, NULL);
  CHECK("a pointer is made on each seat", pointer_a != NULL && pointer_b != NULL && fake_last.proxy == seat_b);
  CHECK("  and nobody listens to the second one yet", ((struct fake_proxy *)pointer_b)->listener == NULL);
  int window = 3;
  CHECK("the embedder listens to its first pointer", wl_proxy_add_listener(pointer_a, plain_listener, &window) == 0 &&
                                                         ((struct fake_proxy *)pointer_a)->listener == plain_listener);
  CHECK("  and the other seat's pointer is given the same listener and data",
        ((struct fake_proxy *)pointer_b)->listener == plain_listener && ((struct fake_proxy *)pointer_b)->data == &window);
  struct wl_proxy *seat_c = fake_proxy(&seat_interface);
  struct wl_proxy *pointer_c = wl_proxy_marshal_flags(seat_c, 0, &pointer_interface, 5, 0, NULL);
  CHECK("  as is a pointer made after that", pointer_c != NULL && ((struct fake_proxy *)pointer_c)->listener == plain_listener &&
                                             ((struct fake_proxy *)pointer_c)->data == &window);
  CHECK("  and the embedder listening to one of them itself is told yes",
        wl_proxy_add_listener(pointer_b, plain_listener, &window) == 0 && ((struct fake_proxy *)pointer_b)->listener == plain_listener);
  CHECK("  while a pointer listened to twice by the embedder is still refused the second time",
        wl_proxy_add_listener(pointer_a, plain_listener, &window) == -1);

  if (failed) {
    printf("     some of it is WRONG\n");
  } else {
    printf("     all as it should be, with %s TV's library\n", new_tv ? "a newer" : "an older");
  }
  return failed;
}
