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
//  * Three functions of the C++ runtime that std::future and std::condition_variable-like waits
//    are built on (std::__atomic_futex_unsigned_base). The TV's own C++ runtime has them; the
//    one VyseTV brings (Debian's, made for an older ARM) has not, so a library of the TV that
//    waits on a std::future would end the app the moment it did, with "symbol lookup error".
//    Measured against webOS Brew's firmware data: webOS 6 to 25 all have these three and
//    nothing else of the kind VyseTV's runtime lacks. Written as the GNU C++ library writes
//    them (libstdc++-v3/src/c++11/futex.cc, GPL-3.0 with the GCC Runtime Library Exception):
//    the kernel's futex call.
//  * snprintf under its other name, __snprintf, and six memory calls of LG's own C library
//    (get_arena_ptr and the like) that webOS 7 and later have and no other C library has: said
//    in the start log when one is asked for, answered with nothing.
//
// (The call every request is sent with, which an older Wayland library also lacks, is in
// vyse_wayland.c: that one has to come first, not last.)
//
// Wayland's own headers are not used: the few types below are the library's public, fixed
// layout, and writing them here keeps this file free of which Wayland the build machine has.

#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

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

// ── the C++ runtime's futex waits (std::__atomic_futex_unsigned_base) ──

enum { kFutexWait = 0, kFutexWake = 1, kFutexWaitBitset = 9, kFutexClockRealtime = 256 };
#define VYSE_BITSET_ANY (~0u)

// (the futex call's own time: 32-bit seconds, whatever this C library's time_t is)
struct vyse_futex_time {
  long tv_sec;
  long tv_nsec;
};

// std::__atomic_futex_unsigned_base::_M_futex_notify_all(unsigned*)
EXPORT void _ZNSt28__atomic_futex_unsigned_base19_M_futex_notify_allEPj(unsigned *addr) {
  syscall(SYS_futex, addr, kFutexWake, INT_MAX);
}

static bool vyse_futex_wait(unsigned *addr, unsigned val, bool has_timeout, long long s, long long ns,
                            bool realtime) {
  if (!has_timeout) {
    syscall(SYS_futex, addr, kFutexWait, val, NULL);
    return true;
  }
  // (an absolute time before the clock's start is past already)
  if (s < 0) return false;
  struct vyse_futex_time at;
  at.tv_sec = s > LONG_MAX ? LONG_MAX : (long)s;
  at.tv_nsec = (long)ns;
  if (syscall(SYS_futex, addr, kFutexWaitBitset | (realtime ? kFutexClockRealtime : 0), val, &at, NULL,
              VYSE_BITSET_ANY) == -1) {
    if (errno == ETIMEDOUT) return false;
    if (errno != ENOSYS) return true;
    // (a kernel without absolute waits: the time left, as a relative one)
    struct timespec now;
    clock_gettime(realtime ? CLOCK_REALTIME : CLOCK_MONOTONIC, &now);
    struct vyse_futex_time left;
    left.tv_sec = (long)(s - now.tv_sec);
    left.tv_nsec = (long)(ns - now.tv_nsec);
    if (left.tv_nsec < 0) {
      left.tv_nsec += 1000000000;
      --left.tv_sec;
    }
    if (left.tv_sec < 0) return false;
    if (syscall(SYS_futex, addr, kFutexWait, val, &left) == -1 && errno == ETIMEDOUT) return false;
  }
  return true;
}

// std::__atomic_futex_unsigned_base::_M_futex_wait_until(unsigned*, unsigned, bool,
//     std::chrono::seconds, std::chrono::nanoseconds), against the wall clock
EXPORT bool _ZNSt28__atomic_futex_unsigned_base19_M_futex_wait_untilEPjjbNSt6chrono8durationIxSt5ratioILx1ELx1EEEENS2_IxS3_ILx1ELx1000000000EEEE(
    unsigned *addr, unsigned val, bool has_timeout, long long s, long long ns) {
  return vyse_futex_wait(addr, val, has_timeout, s, ns, true);
}

// ... and _M_futex_wait_until_steady, against the clock that never jumps
EXPORT bool _ZNSt28__atomic_futex_unsigned_base26_M_futex_wait_until_steadyEPjjbNSt6chrono8durationIxSt5ratioILx1ELx1EEEENS2_IxS3_ILx1ELx1000000000EEEE(
    unsigned *addr, unsigned val, bool has_timeout, long long s, long long ns) {
  return vyse_futex_wait(addr, val, has_timeout, s, ns, false);
}

// ── the C library's: snprintf's other name, and LG's own memory calls ──

EXPORT int __snprintf(char *out, size_t size, const char *format, ...) {
  va_list args;
  va_start(args, format);
  const int n = vsnprintf(out, size, format, args);
  va_end(args);
  return n;
}

#define VYSE_LG_MALLOC(name)                                                                    \
  EXPORT void *name(void) {                                                                     \
    fprintf(stderr, "[vyse] a library of the TV asked for LG's " #name "(): answered with nothing\n"); \
    return NULL;                                                                                \
  }
VYSE_LG_MALLOC(get_arena_ptr)
VYSE_LG_MALLOC(put_arena_ptr)
VYSE_LG_MALLOC(get_heap_info)
VYSE_LG_MALLOC(get_heap_info_next)
VYSE_LG_MALLOC(malloc_info_fragmentation)
VYSE_LG_MALLOC(malloc_info_trace)

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
