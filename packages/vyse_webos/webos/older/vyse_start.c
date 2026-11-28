// VyseTV on an older webOS: a record of how the app started, and of how it ended if it fell.
//
// On an older webOS the app runs on a system runtime it brings itself, under LG's embedder,
// which was made for webOS 26. Nobody here has such a TV, so when it does not come up the only
// thing a tester can send back is what the app wrote down. In the package for older webOS this
// library is made part of the app's program (build.sh), and before anything else runs it:
//
//   * sends everything the app prints (its own lines, the embedder's, the loader's) to a file,
//     appdata/vysetv-start.log in the app's folder (or /tmp/vysetv-start.log);
//   * starts that file with what it is running on: the kernel, the TV's own description of its
//     webOS, and every program and library that was loaded, each with where it came from (the
//     app's own runtime or the TV's);
//   * should the app fall (a fault in native code), adds which signal, where, and the map of
//     what is loaded where, so the place can be found in the files the package was made of;
//   * should it end any other way, says how: a library calling exit() or _exit() (which one,
//     and from where), or a signal that stops it (SIGTERM and the like, with the program that
//     sent it). A webOS 25 tester's log simply ended, with none of the above (2026-11-28).
//
// The file is started afresh each time the app starts. See webos/README.md, "Older webOS".

#define _GNU_SOURCE

#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

// ── writing without the C library's buffers (also from inside a fault) ──

static void vyse_put(const char *text) {
  size_t left = strlen(text);
  while (left > 0) {
    const ssize_t n = write(2, text, left);
    if (n <= 0) return;
    text += n;
    left -= (size_t)n;
  }
}

static void vyse_put_hex(unsigned long value) {
  char out[2 + 2 * sizeof value + 1];
  int at = (int)sizeof out - 1;
  out[at] = '\0';
  do {
    out[--at] = "0123456789abcdef"[value & 15u];
    value >>= 4;
  } while (value != 0 && at > 2);
  out[--at] = 'x';
  out[--at] = '0';
  vyse_put(out + at);
}

static void vyse_put_number(long value) {
  char out[24];
  int at = (int)sizeof out - 1;
  const int negative = value < 0;
  unsigned long v = negative ? (unsigned long)(-value) : (unsigned long)value;
  out[at] = '\0';
  do {
    out[--at] = (char)('0' + v % 10);
    v /= 10;
  } while (v != 0 && at > 1);
  if (negative) out[--at] = '-';
  vyse_put(out + at);
}

static void vyse_put_file(const char *path, size_t most) {
  const int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    vyse_put("(not readable)\n");
    return;
  }
  char buf[1024];
  size_t total = 0;
  for (;;) {
    const ssize_t n = read(fd, buf, sizeof buf);
    if (n <= 0) break;
    size_t take = (size_t)n;
    if (total + take > most) take = most - total;
    size_t done = 0;
    while (done < take) {
      const ssize_t w = write(2, buf + done, take - done);
      if (w <= 0) break;
      done += (size_t)w;
    }
    total += take;
    if (total >= most) break;
  }
  close(fd);
  if (total == 0 || total >= most) vyse_put("\n");
}

// ── a fault ──

static void vyse_fell(int sig, siginfo_t *info, void *context) {
  vyse_put("\n[vyse] THE APP FELL: signal ");
  vyse_put_number(sig);
  vyse_put(sig == SIGSEGV ? " (bad memory access)" : sig == SIGABRT ? " (gave up: abort)" : sig == SIGBUS ? " (bus error)" : sig == SIGILL ? " (instruction this chip does not have)" : sig == SIGFPE ? " (arithmetic)" : "");
  vyse_put(", at address ");
  vyse_put_hex(info != NULL ? (unsigned long)(uintptr_t)info->si_addr : 0ul);
#if defined(__arm__)
  if (context != NULL) {
    const ucontext_t *uc = (const ucontext_t *)context;
    vyse_put(", pc ");
    vyse_put_hex(uc->uc_mcontext.arm_pc);
    vyse_put(", lr ");
    vyse_put_hex(uc->uc_mcontext.arm_lr);
    vyse_put(", sp ");
    vyse_put_hex(uc->uc_mcontext.arm_sp);
  }
#else
  (void)context;
#endif
  vyse_put("\n[vyse] what is loaded where (pc and lr fall inside one of these):\n");
  vyse_put_file("/proc/self/maps", 400000);
  vyse_put("[vyse] end of the record\n");
  // (and on to what would have happened without this: the signal's own ending)
  signal(sig, SIG_DFL);
  raise(sig);
}

// ── an ending that is not a fault ──

// (the app's own process; a child of it, between fork and exec, is left alone)
static pid_t vyse_main_pid;
static void (*vyse_real_exit)(int);

static void vyse_put_sender(const siginfo_t *info) {
  if (info == NULL || info->si_code > 0 || info->si_pid <= 0) return;
  vyse_put(", sent by process ");
  vyse_put_number((long)info->si_pid);
  char path[48];
  // (its command line, NULs and all, read as it is: open, read and write are safe here)
  snprintf(path, sizeof path, "/proc/%d/cmdline", (int)info->si_pid);
  vyse_put(": ");
  vyse_put_file(path, 200);
}

static void vyse_stopped(int sig, siginfo_t *info, void *context) {
  (void)context;
  vyse_put("\n[vyse] THE APP WAS STOPPED: signal ");
  vyse_put_number(sig);
  vyse_put(sig == SIGTERM ? " (SIGTERM: asked to close)" : sig == SIGHUP ? " (SIGHUP)" : sig == SIGQUIT ? " (SIGQUIT)" : sig == SIGSYS ? " (SIGSYS: a system call this TV refuses)" : sig == SIGXCPU ? " (SIGXCPU: out of processor time)" : "");
  vyse_put_sender(info);
  vyse_put("\n");
  signal(sig, SIG_DFL);
  raise(sig);
}

static void vyse_leaving(const char *how, int code, void *from) {
  if (getpid() != vyse_main_pid) return;
  vyse_put("\n[vyse] THE APP IS LEAVING: ");
  vyse_put(how);
  vyse_put("(");
  vyse_put_number(code);
  vyse_put(")");
  Dl_info where;
  memset(&where, 0, sizeof where);
  if (from != NULL && dladdr(from, &where) != 0 && where.dli_fname != NULL) {
    vyse_put(", called from ");
    vyse_put(where.dli_fname);
    if (where.dli_sname != NULL) {
      vyse_put(" (in ");
      vyse_put(where.dli_sname);
      vyse_put(")");
    }
    vyse_put(" at ");
    vyse_put_hex((unsigned long)((uintptr_t)from - (uintptr_t)where.dli_fbase));
  } else {
    vyse_put(", called from ");
    vyse_put_hex((unsigned long)(uintptr_t)from);
  }
  vyse_put("\n");
}

// exit() and _exit() as every library of the app calls them: said, then done as the C library
// does them. (This library is one the program needs, ahead of the C library, so its two are the
// ones found.)
__attribute__((visibility("default"), noreturn)) void exit(int code) {
  vyse_leaving("exit", code, __builtin_return_address(0));
  if (vyse_real_exit != NULL) vyse_real_exit(code);
  for (;;) syscall(SYS_exit_group, code);
}

__attribute__((visibility("default"), noreturn)) void _exit(int code) {
  vyse_leaving("_exit", code, __builtin_return_address(0));
  for (;;) syscall(SYS_exit_group, code);
}

__attribute__((visibility("default"), noreturn)) void _Exit(int code) {
  vyse_leaving("_Exit", code, __builtin_return_address(0));
  for (;;) syscall(SYS_exit_group, code);
}

// ── the start ──

static void vyse_loaded(void) {
  // Each file that is mapped as code, once: the program, the runtime, every library.
  FILE *maps = fopen("/proc/self/maps", "re");
  if (maps == NULL) {
    vyse_put("(no /proc/self/maps)\n");
    return;
  }
  char line[768];
  char last[512] = "";
  while (fgets(line, sizeof line, maps) != NULL) {
    char perms[8] = "";
    char path[512] = "";
    if (sscanf(line, "%*s %7s %*s %*s %*s %511[^\n]", perms, path) < 2) continue;
    if (perms[2] != 'x' || path[0] != '/') continue;
    if (strcmp(path, last) == 0) continue;
    snprintf(last, sizeof last, "%s", path);
    vyse_put("  ");
    vyse_put(path);
    vyse_put("\n");
  }
  fclose(maps);
}

__attribute__((constructor)) static void vyse_started(void) {
  // Where: appdata/ in the app's folder (the one folder of it the app may write), else /tmp.
  char path[640];
  int fd = -1;
  const ssize_t n = readlink("/proc/self/exe", path, 512);
  if (n > 0) {
    path[n] = '\0';
    char *slash = strrchr(path, '/');
    if (slash != NULL) {
      snprintf(slash, sizeof path - (size_t)(slash - path), "/appdata/vysetv-start.log");
      fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    }
  }
  if (fd < 0) {
    snprintf(path, sizeof path, "/tmp/vysetv-start.log");
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  }
  if (fd >= 0) {
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2) close(fd);
    // (a line at a time: what was printed last is in the file when the app falls)
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
  }

  vyse_put("[vyse] VyseTV for older webOS, starting. This file: ");
  vyse_put(path);
  vyse_put("\n[vyse] time: ");
  vyse_put_number((long)time(NULL));
  struct utsname un;
  if (uname(&un) == 0) {
    vyse_put("\n[vyse] kernel: ");
    vyse_put(un.sysname);
    vyse_put(" ");
    vyse_put(un.release);
    vyse_put(" ");
    vyse_put(un.machine);
  }
  vyse_put("\n[vyse] the TV says of itself (/var/run/nyx/os_info.json): ");
  vyse_put_file("/var/run/nyx/os_info.json", 1500);
  vyse_put("[vyse] loaded as the app started:\n");
  vyse_loaded();
  vyse_put("[vyse] from here on: what the app and LG's embedder print\n");

  struct sigaction act;
  memset(&act, 0, sizeof act);
  act.sa_sigaction = vyse_fell;
  act.sa_flags = SA_SIGINFO | SA_RESETHAND;
  sigemptyset(&act.sa_mask);
  static const int faults[] = {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE};
  for (size_t i = 0; i < sizeof faults / sizeof faults[0]; i++) sigaction(faults[i], &act, NULL);

  vyse_main_pid = getpid();
  vyse_real_exit = (void (*)(int))dlsym(RTLD_NEXT, "exit");
  act.sa_sigaction = vyse_stopped;
  static const int stops[] = {SIGTERM, SIGHUP, SIGQUIT, SIGSYS, SIGXCPU};
  for (size_t i = 0; i < sizeof stops / sizeof stops[0]; i++) sigaction(stops[i], &act, NULL);
}
