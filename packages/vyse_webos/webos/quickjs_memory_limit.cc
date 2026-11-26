// The one function flutter_js's Dart side knows that the bridge's own source does not have
// (and so neither does the library flutter_js ships for desktop Linux): a cap on how much
// memory one script may take. Compiled into the same library, it gives a scraper plugin on a
// TV the limit it has on Android, where it matters most: a TV has little memory to lose.

#include <stddef.h>

#include "quickjs/quickjs.h"

extern "C" __attribute__((visibility("default"))) __attribute__((used)) void jsSetMemoryLimit(JSRuntime* rt, size_t limit) {
  JS_SetMemoryLimit(rt, limit);
}
