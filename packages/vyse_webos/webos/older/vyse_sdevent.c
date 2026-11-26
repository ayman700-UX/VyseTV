// VyseTV on an older webOS: the event loop LG's Flutter embedder runs on.
//
// The embedder's main loop is systemd's "sd-event" (ten functions of libsystemd). webOS 5 and
// later have that library; webOS 4 has no libsystemd at all, so there the app could not even
// be loaded. In the package for older webOS the embedder is pointed at this library instead of
// libsystemd (build.sh). On a TV that has libsystemd every call is passed straight on to it,
// and nothing below the dashed line runs. On a TV that has none, the loop below does the job:
// the same ten functions, over the kernel's epoll, with the meaning systemd's own manual gives
// them (sd_event_add_io(3), sd_event_add_time(3), sd_event_add_defer(3),
// sd_event_source_set_enabled(3), sd_event_loop(3), sd_event_exit(3)).
//
// One loop, one thread, as sd-event itself: none of it may be called from another thread.
// See webos/README.md, "Older webOS".

#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <time.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

typedef struct sd_event sd_event;
typedef struct sd_event_source sd_event_source;
typedef int (*sd_event_io_handler_t)(sd_event_source *s, int fd, uint32_t revents, void *userdata);
typedef int (*sd_event_time_handler_t)(sd_event_source *s, uint64_t usec, void *userdata);
typedef int (*sd_event_handler_t)(sd_event_source *s, void *userdata);

enum { SD_EVENT_OFF = 0, SD_EVENT_ON = 1, SD_EVENT_ONESHOT = -1 };

// libvyse_fallback.so
extern int vyse_fallback_present(void);

// ── the TV's own libsystemd, when it has one ──

static struct {
  int looked;
  void *lib;
  int (*new_)(sd_event **);
  sd_event *(*unref)(sd_event *);
  int (*add_io)(sd_event *, sd_event_source **, int, uint32_t, sd_event_io_handler_t, void *);
  int (*add_time)(sd_event *, sd_event_source **, clockid_t, uint64_t, uint64_t, sd_event_time_handler_t, void *);
  int (*add_defer)(sd_event *, sd_event_source **, sd_event_handler_t, void *);
  int (*loop)(sd_event *);
  int (*exit_)(sd_event *, int);
  int (*set_enabled)(sd_event_source *, int);
  int (*set_time)(sd_event_source *, uint64_t);
  sd_event_source *(*source_unref)(sd_event_source *);
} real;

// True when the TV's libsystemd is there and has all ten: then it is used for everything.
// (Never half and half: a loop made by one cannot be run by the other.)
static int vyse_have_real(void) {
  if (real.looked) return real.lib != NULL;
  real.looked = 1;
  // (what makes vyse_fallback a library this one needs: see the note there)
  (void)vyse_fallback_present();
  void *lib = dlopen("libsystemd.so.0", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) {
    fprintf(stderr, "[vyse] no libsystemd on this TV: the app's own event loop is used\n");
    return 0;
  }
  real.new_ = (int (*)(sd_event **))dlsym(lib, "sd_event_new");
  real.unref = (sd_event * (*)(sd_event *)) dlsym(lib, "sd_event_unref");
  real.add_io = (int (*)(sd_event *, sd_event_source **, int, uint32_t, sd_event_io_handler_t, void *))dlsym(lib, "sd_event_add_io");
  real.add_time =
      (int (*)(sd_event *, sd_event_source **, clockid_t, uint64_t, uint64_t, sd_event_time_handler_t, void *))dlsym(lib, "sd_event_add_time");
  real.add_defer = (int (*)(sd_event *, sd_event_source **, sd_event_handler_t, void *))dlsym(lib, "sd_event_add_defer");
  real.loop = (int (*)(sd_event *))dlsym(lib, "sd_event_loop");
  real.exit_ = (int (*)(sd_event *, int))dlsym(lib, "sd_event_exit");
  real.set_enabled = (int (*)(sd_event_source *, int))dlsym(lib, "sd_event_source_set_enabled");
  real.set_time = (int (*)(sd_event_source *, uint64_t))dlsym(lib, "sd_event_source_set_time");
  real.source_unref = (sd_event_source * (*)(sd_event_source *)) dlsym(lib, "sd_event_source_unref");
  if (real.new_ == NULL || real.unref == NULL || real.add_io == NULL || real.add_time == NULL || real.add_defer == NULL ||
      real.loop == NULL || real.exit_ == NULL || real.set_enabled == NULL || real.set_time == NULL || real.source_unref == NULL) {
    fprintf(stderr, "[vyse] this TV's libsystemd lacks part of sd-event: the app's own event loop is used\n");
    return 0;
  }
  real.lib = lib;
  return 1;
}

// ─────────────────────────── the app's own loop ───────────────────────────

enum { VYSE_IO, VYSE_TIME, VYSE_DEFER };

struct sd_event_source {
  sd_event *event;
  int refs;
  int kind;
  int enabled;    // SD_EVENT_OFF, _ON or _ONESHOT
  int floating;   // nobody was handed it: it is the loop's, and goes with the loop
  int in_epoll;   // (an io source: registered with the kernel now)
  int pending;    // found ready in this turn of the loop
  int holds;      // the loop is in the middle of a turn that has it on its list
  int gone;       // let go of by its last holder while the loop still had it on its list
  int fd;
  uint32_t events;
  uint32_t revents;
  clockid_t clock;
  uint64_t usec;  // when a time source is due, on its own clock
  sd_event_io_handler_t on_io;
  sd_event_time_handler_t on_time;
  sd_event_handler_t on_defer;
  void *userdata;
  sd_event_source *next;
};

struct sd_event {
  int refs;
  int epoll;
  int leaving;
  int code;
  sd_event_source *sources;
};

static uint64_t vyse_now(clockid_t clock) {
  struct timespec ts;
  if (clock_gettime(clock, &ts) != 0) clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

static void vyse_watch(sd_event_source *s, int on) {
  if (s->kind != VYSE_IO || s->event == NULL) return;
  if (on && !s->in_epoll) {
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = s->events;
    ev.data.ptr = s;
    if (epoll_ctl(s->event->epoll, EPOLL_CTL_ADD, s->fd, &ev) == 0) s->in_epoll = 1;
  } else if (!on && s->in_epoll) {
    epoll_ctl(s->event->epoll, EPOLL_CTL_DEL, s->fd, NULL);
    s->in_epoll = 0;
  }
}

// Takes a source out of its loop (it may live on, held by whoever still has it).
static void vyse_detach(sd_event_source *s) {
  sd_event *e = s->event;
  if (e == NULL) return;
  vyse_watch(s, 0);
  for (sd_event_source **p = &e->sources; *p != NULL; p = &(*p)->next) {
    if (*p == s) {
      *p = s->next;
      break;
    }
  }
  s->next = NULL;
  s->event = NULL;
  s->enabled = SD_EVENT_OFF;
  s->pending = 0;
}

static sd_event_source *vyse_source(sd_event *e, sd_event_source **ret, int kind, int enabled, void *userdata) {
  sd_event_source *s = calloc(1, sizeof *s);
  if (s == NULL) return NULL;
  s->event = e;
  s->refs = 1;
  s->kind = kind;
  s->enabled = enabled;
  s->floating = ret == NULL;
  s->fd = -1;
  s->userdata = userdata;
  s->next = e->sources;
  e->sources = s;
  if (ret != NULL) *ret = s;
  return s;
}

// The last holder letting go takes the source out of the loop at once: it is never called
// again, also not later in the turn that is running. Its memory waits for that turn to end.
static sd_event_source *vyse_source_unref(sd_event_source *s) {
  if (s == NULL) return NULL;
  if (--s->refs > 0) return NULL;
  vyse_detach(s);
  if (s->holds > 0) {
    s->gone = 1;
  } else {
    free(s);
  }
  return NULL;
}

static int vyse_new(sd_event **ret) {
  if (ret == NULL) return -EINVAL;
  sd_event *e = calloc(1, sizeof *e);
  if (e == NULL) return -ENOMEM;
  e->refs = 1;
  e->epoll = epoll_create1(EPOLL_CLOEXEC);
  if (e->epoll < 0) {
    const int err = errno;
    free(e);
    return -err;
  }
  *ret = e;
  return 0;
}

static sd_event *vyse_unref(sd_event *e) {
  if (e == NULL) return NULL;
  if (--e->refs > 0) return NULL;
  while (e->sources != NULL) {
    sd_event_source *s = e->sources;
    const int its_own = s->floating;
    vyse_detach(s);
    // (one somebody still holds is theirs to let go; one on a running turn's list goes when
    // that turn ends)
    if (its_own) {
      if (s->holds > 0) {
        s->gone = 1;
      } else {
        free(s);
      }
    }
  }
  close(e->epoll);
  free(e);
  return NULL;
}

// One turn: wait for what is ready, then call each ready source once.
static int vyse_turn(sd_event *e) {
  // How long to wait: not at all with a deferred call waiting, until the next time source is
  // due otherwise, for ever with neither.
  int timeout = -1;
  for (sd_event_source *s = e->sources; s != NULL; s = s->next) {
    if (s->enabled == SD_EVENT_OFF) continue;
    if (s->kind == VYSE_DEFER) {
      timeout = 0;
      break;
    }
    if (s->kind == VYSE_TIME) {
      const uint64_t now = vyse_now(s->clock);
      const uint64_t left = s->usec > now ? s->usec - now : 0;
      // (rounded up: woken a moment late beats spinning until it is due)
      const uint64_t ms = (left + 999) / 1000;
      const int wait = ms > 3600000u ? 3600000 : (int)ms;
      if (timeout < 0 || wait < timeout) timeout = wait;
    }
  }

  struct epoll_event ready[32];
  int n = epoll_wait(e->epoll, ready, 32, timeout);
  if (n < 0) {
    if (errno == EINTR) return 0;
    return -errno;
  }

  // What is ready now. Marked first and called after: a call may add, switch off or let go
  // of any source, this one included.
  int count = 0;
  for (int i = 0; i < n; i++) {
    sd_event_source *s = ready[i].data.ptr;
    if (s != NULL && s->enabled != SD_EVENT_OFF) {
      s->revents = ready[i].events;
      s->pending = 1;
    }
  }
  for (sd_event_source *s = e->sources; s != NULL; s = s->next) {
    if (s->enabled == SD_EVENT_OFF) continue;
    if (s->kind == VYSE_DEFER) s->pending = 1;
    if (s->kind == VYSE_TIME && vyse_now(s->clock) >= s->usec) s->pending = 1;
    if (s->pending) count++;
  }
  if (count == 0) return 0;

  sd_event_source **calls = calloc((size_t)count, sizeof *calls);
  if (calls == NULL) return -ENOMEM;
  int k = 0;
  for (sd_event_source *s = e->sources; s != NULL && k < count; s = s->next) {
    if (!s->pending) continue;
    s->pending = 0;
    s->holds++;  // (its memory stays until this turn is over, whatever the calls before it do)
    calls[k++] = s;
  }

  for (int i = 0; i < k; i++) {
    sd_event_source *s = calls[i];
    // (let go of, or switched off, by a call made earlier in this turn)
    if (s->event == e && s->enabled != SD_EVENT_OFF && !e->leaving) {
      if (s->enabled == SD_EVENT_ONESHOT) {
        s->enabled = SD_EVENT_OFF;
        vyse_watch(s, 0);
      }
      int r = 0;
      if (s->kind == VYSE_IO && s->on_io != NULL) r = s->on_io(s, s->fd, s->revents, s->userdata);
      if (s->kind == VYSE_TIME && s->on_time != NULL) r = s->on_time(s, s->usec, s->userdata);
      if (s->kind == VYSE_DEFER && s->on_defer != NULL) r = s->on_defer(s, s->userdata);
      // (a call that fails switches its source off, as sd-event does)
      if (r < 0 && s->event == e) {
        s->enabled = SD_EVENT_OFF;
        vyse_watch(s, 0);
      }
    }
    if (--s->holds == 0 && s->gone) free(s);
  }
  free(calls);
  return 0;
}

// ─────────────────────────── the ten functions ───────────────────────────

EXPORT int sd_event_new(sd_event **ret) { return vyse_have_real() ? real.new_(ret) : vyse_new(ret); }

EXPORT sd_event *sd_event_unref(sd_event *e) { return vyse_have_real() ? real.unref(e) : vyse_unref(e); }

EXPORT int sd_event_add_io(sd_event *e, sd_event_source **ret, int fd, uint32_t events, sd_event_io_handler_t callback, void *userdata) {
  if (vyse_have_real()) return real.add_io(e, ret, fd, events, callback, userdata);
  if (e == NULL || fd < 0 || callback == NULL) return -EINVAL;
  sd_event_source *s = vyse_source(e, ret, VYSE_IO, SD_EVENT_ON, userdata);
  if (s == NULL) return -ENOMEM;
  s->fd = fd;
  s->events = events;
  s->on_io = callback;
  vyse_watch(s, 1);
  if (!s->in_epoll) {
    const int err = errno;
    if (ret != NULL) *ret = NULL;
    vyse_detach(s);
    free(s);
    return -err;
  }
  return 0;
}

EXPORT int sd_event_add_time(sd_event *e, sd_event_source **ret, clockid_t clock, uint64_t usec, uint64_t accuracy,
                             sd_event_time_handler_t callback, void *userdata) {
  if (vyse_have_real()) return real.add_time(e, ret, clock, usec, accuracy, callback, userdata);
  (void)accuracy;
  if (e == NULL) return -EINVAL;
  sd_event_source *s = vyse_source(e, ret, VYSE_TIME, SD_EVENT_ONESHOT, userdata);
  if (s == NULL) return -ENOMEM;
  s->clock = clock;
  s->usec = usec;
  s->on_time = callback;
  return 0;
}

EXPORT int sd_event_add_defer(sd_event *e, sd_event_source **ret, sd_event_handler_t callback, void *userdata) {
  if (vyse_have_real()) return real.add_defer(e, ret, callback, userdata);
  if (e == NULL) return -EINVAL;
  sd_event_source *s = vyse_source(e, ret, VYSE_DEFER, SD_EVENT_ONESHOT, userdata);
  if (s == NULL) return -ENOMEM;
  s->on_defer = callback;
  return 0;
}

EXPORT int sd_event_loop(sd_event *e) {
  if (vyse_have_real()) return real.loop(e);
  if (e == NULL) return -EINVAL;
  e->refs++;
  int r = 0;
  while (!e->leaving && r == 0) r = vyse_turn(e);
  const int code = r < 0 ? r : e->code;
  vyse_unref(e);
  return code;
}

EXPORT int sd_event_exit(sd_event *e, int code) {
  if (vyse_have_real()) return real.exit_(e, code);
  if (e == NULL) return -EINVAL;
  e->leaving = 1;
  e->code = code;
  return 0;
}

EXPORT int sd_event_source_set_enabled(sd_event_source *s, int enabled) {
  if (vyse_have_real()) return real.set_enabled(s, enabled);
  if (s == NULL) return -EINVAL;
  if (enabled != SD_EVENT_OFF && enabled != SD_EVENT_ON && enabled != SD_EVENT_ONESHOT) return -EINVAL;
  if (s->event == NULL) return -ESTALE;
  s->enabled = enabled;
  vyse_watch(s, enabled != SD_EVENT_OFF);
  return 0;
}

EXPORT int sd_event_source_set_time(sd_event_source *s, uint64_t usec) {
  if (vyse_have_real()) return real.set_time(s, usec);
  if (s == NULL || s->kind != VYSE_TIME) return -EINVAL;
  s->usec = usec;
  s->pending = 0;
  return 0;
}

EXPORT sd_event_source *sd_event_source_unref(sd_event_source *s) {
  if (vyse_have_real()) return real.source_unref(s);
  return vyse_source_unref(s);
}
