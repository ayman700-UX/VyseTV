// VyseTV's native side on LG webOS.
//
// Two things, both thin on purpose:
//
//  1. The TV's own media player. LG's NDL media library (NDL/NDL_media.h, in LG's NDK) is a C
//     front for the system service that plays an address: the TV fetches it, reads the
//     container, decodes in hardware and shows the picture on its video plane. This file
//     passes the app's calls on to it and hands its events back exactly as they come (a JSON
//     text per event). Nothing is decided here: what an event means, what to tell the TV when
//     a video opens, subtitles, errors, all of that is Dart
//     (lib/mpv/player/platform/player_webos.dart), where it is tested.
//
//     The calls and their order follow LG's own Flutter video plugin
//     (lg-flutter-webos/plugins, packages/video_player and video_player_drm, BSD-3-Clause),
//     including what its comments say about tearing a player down: a slot, once started, is
//     kept for the life of the process and never "quit".
//
//  2. Properties of the app's window. A webOS window only gets the remote's Back key when it
//     says it wants it (_WEBOS_ACCESS_POLICY_KEYS_BACK); otherwise the TV answers Back itself
//     with its "close the app?" question.
//
// Older webOS. LG's Flutter SDK is for webOS 26, and this file is built against webOS 26's
// libraries; the same build is also packaged for older sets (tool/webos/build.sh, "older
// webOS"). Their media library is the same one with fewer calls, so the calls that came later
// are asked for before they are used (see "What this TV has" below), and each has an older
// way: a player started without a window id (the id still goes in what the TV is told with the
// address), one player that the film and the music take turns at instead of one each, and on
// sets that cannot place a window under the app at all (webOS 4) the picture placed by the
// media library itself. And there the media library takes its window from SDL, so VyseTV
// gives it a stand-in for SDL that answers with the app's window (UseWindowForOlderLibrary).

#include "include/vyse_webos/vyse_webos_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>
#include <flutter_webos.h>

#include <NDL/NDL_media.h>
#include <dlfcn.h>
#include <glib.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <utility>

// What this TV has. These calls of LG's media library came with a later webOS than the oldest
// set this is packaged for (the first webOS that has each, from webOS Brew's firmware data).
// Declared weak, the app still loads where one is missing, and its address says whether it is
// there.
#pragma weak NDL_MediaInitWithWindowId  // webOS 26
#pragma weak NDL_MediaSetPlayer         // webOS 6
#pragma weak NDL_MediaMuteDisplay       // webOS 5

#ifdef VYSE_HAVE_NDL_SET_DISPLAY_WINDOW
// Every webOS has this one. It is how the picture is placed where there are no exported
// windows (webOS 4); newer sets place the window instead.
#pragma weak NDL_MediaSetDisplayWindow
#endif

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

typedef flutter::MethodCall<EncodableValue> Call;
typedef std::unique_ptr<flutter::MethodResult<EncodableValue>> Reply;

// The film, music, and a watch party's music beside the app's own. (LG's library has five
// slots; LG's own audio plugin counts its players up from slot 0 too, so that plugin is not
// used in this app: two plugins would each think slot 0 theirs.)
constexpr int kSlots = 3;

constexpr char kWantsBack[] = "_WEBOS_ACCESS_POLICY_KEYS_BACK";

struct Slot {
  // Started in LG's library (once per process: see the note at the top).
  bool started = false;
  bool loaded = false;
  // The Dart player that has this slot now. A "dispose" from an older one is not for us.
  int64_t owner = 0;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> methods;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink;
};

class VyseWebosPlugin;
VyseWebosPlugin* g_plugin = nullptr;

// Events arrive on a thread of LG's library. They wait here until the main loop takes them.
std::mutex g_queue_mutex;
std::deque<std::pair<int, std::string>> g_queue;
bool g_drain_scheduled = false;
GMainContext* g_main_context = nullptr;

gboolean DrainOnMainLoop(gpointer);

void Enqueue(int slot, const char* json) {
  if (json == nullptr) return;
  std::lock_guard<std::mutex> lock(g_queue_mutex);
  g_queue.emplace_back(slot, std::string(json));
  if (g_drain_scheduled || g_main_context == nullptr) return;
  g_drain_scheduled = true;
  GSource* source = g_idle_source_new();
  g_source_set_callback(source, DrainOnMainLoop, nullptr, nullptr);
  g_source_attach(source, g_main_context);
  g_source_unref(source);
}

// LG's library calls back with the text alone, so each slot has a function of its own.
void OnSlot0(char* json) { Enqueue(0, json); }
void OnSlot1(char* json) { Enqueue(1, json); }
void OnSlot2(char* json) { Enqueue(2, json); }

void (*const kOnSlot[kSlots])(char*) = {OnSlot0, OnSlot1, OnSlot2};

// A TV whose library has one player (before webOS 6): the slots take turns at it, and what it
// says goes to the slot that has it now.
std::atomic<int> g_holder{-1};
void OnShared(char* json) {
  const int slot = g_holder.load();
  if (slot >= 0) Enqueue(slot, json);
}

bool HasInitWithWindowId() { return &NDL_MediaInitWithWindowId != nullptr; }
bool HasPlayers() { return &NDL_MediaSetPlayer != nullptr; }
bool HasMuteDisplay() { return &NDL_MediaMuteDisplay != nullptr; }

bool HasDisplayWindow() {
#ifdef VYSE_HAVE_NDL_SET_DISPLAY_WINDOW
  return &NDL_MediaSetDisplayWindow != nullptr;
#else
  return false;
#endif
}

// The window the next player of an older TV's media library is to show its picture in ("":
// sound alone). Before webOS 26 that library cannot be handed a window: when a player starts
// it asks SDL for one, and an app without SDL gave it nothing, which ended the app on the spot
// (an LG webOS 5.6 tester, 2026-11-27: "App closes when playing any media"). VyseTV's stand-in
// for SDL (older/vyse_sdl.c, which carries SDL's name) is loaded here before the first player
// starts, so the library's request for SDL finds it, and it is told the window each time.
void UseWindowForOlderLibrary(const std::string& window) {
  static void (*use)(const char*) = nullptr;
  static bool looked = false;
  if (!looked) {
    looked = true;
    // (an SDL already in the process would be the one found: there is none in this app)
    if (void* sdl = dlopen("libSDL2-2.0.so.0", RTLD_NOW | RTLD_NOLOAD)) {
      std::fprintf(stderr, "[vyse_webos] an SDL is loaded already: the media library asks that one\n");
      dlclose(sdl);
    }
    // (beside this library, in the app's lib/)
    std::string path = "libvyse_sdl.so";
    Dl_info self{};
    if (dladdr(reinterpret_cast<void*>(&UseWindowForOlderLibrary), &self) != 0 &&
        self.dli_fname != nullptr) {
      const std::string here(self.dli_fname);
      const size_t slash = here.rfind('/');
      if (slash != std::string::npos) path = here.substr(0, slash + 1) + "libvyse_sdl.so";
    }
    void* standin = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (standin == nullptr) standin = dlopen("libvyse_sdl.so", RTLD_NOW | RTLD_GLOBAL);
    if (standin != nullptr) {
      use = reinterpret_cast<void (*)(const char*)>(dlsym(standin, "VyseSdlUseWindow"));
    }
    std::fprintf(stderr, "[vyse_webos] the media library's SDL: %s\n",
                 use != nullptr ? "VyseTV's stand-in" : dlerror());
  }
  if (use != nullptr) use(window.c_str());
}

// Whether the TV can put a window of its video plane under the app ("exported windows",
// webOS 5 and later): asked of the TV's own library, which has the protocol for it or has not.
bool HasExportedWindows() {
  void* lib = dlopen("libwayland-webos-client.so.1", RTLD_LAZY | RTLD_NOLOAD);
  if (lib == nullptr) lib = dlopen("libwayland-webos-client.so.1", RTLD_LAZY);
  if (lib == nullptr) return false;
  const bool has = dlsym(lib, "wl_webos_foreign_interface") != nullptr;
  dlclose(lib);
  return has;
}

// What LG's library says went wrong, whatever type it says it in.
std::string LastError() {
  std::ostringstream out;
  out << NDL_MediaGetError();
  return out.str();
}

const EncodableValue* Find(const EncodableValue* args, const char* key) {
  if (args == nullptr) return nullptr;
  const EncodableMap* map = std::get_if<EncodableMap>(args);
  if (map == nullptr) return nullptr;
  auto it = map->find(EncodableValue(std::string(key)));
  return it == map->end() ? nullptr : &it->second;
}

std::string TextArg(const EncodableValue* args, const char* key) {
  const EncodableValue* v = Find(args, key);
  if (v == nullptr) return std::string();
  const std::string* s = std::get_if<std::string>(v);
  return s == nullptr ? std::string() : *s;
}

int64_t IntArg(const EncodableValue* args, const char* key, int64_t fallback) {
  const EncodableValue* v = Find(args, key);
  if (v == nullptr) return fallback;
  if (const int32_t* i = std::get_if<int32_t>(v)) return *i;
  if (const int64_t* l = std::get_if<int64_t>(v)) return *l;
  if (const double* d = std::get_if<double>(v)) return static_cast<int64_t>(*d);
  return fallback;
}

double NumberArg(const EncodableValue* args, const char* key, double fallback) {
  const EncodableValue* v = Find(args, key);
  if (v == nullptr) return fallback;
  if (const double* d = std::get_if<double>(v)) return *d;
  if (const int32_t* i = std::get_if<int32_t>(v)) return static_cast<double>(*i);
  if (const int64_t* l = std::get_if<int64_t>(v)) return static_cast<double>(*l);
  return fallback;
}

bool FlagArg(const EncodableValue* args, const char* key, bool fallback) {
  const EncodableValue* v = Find(args, key);
  if (v == nullptr) return fallback;
  const bool* b = std::get_if<bool>(v);
  return b == nullptr ? fallback : *b;
}

class VyseWebosPlugin : public flutter::Plugin {
 public:
  VyseWebosPlugin(flutter::PluginRegistrar* registrar, FlutterDesktopViewRef view)
      : view_(view) {
    g_plugin = this;
    {
      std::lock_guard<std::mutex> lock(g_queue_mutex);
      if (g_main_context == nullptr) {
        g_main_context = g_main_context_ref_thread_default();
      }
    }

    const flutter::StandardMethodCodec* codec =
        &flutter::StandardMethodCodec::GetInstance();
    for (int i = 0; i < kSlots; ++i) {
      const std::string name = "vyse/webos_media/" + std::to_string(i);
      slots_[i].methods =
          std::make_unique<flutter::MethodChannel<EncodableValue>>(
              registrar->messenger(), name, codec);
      slots_[i].methods->SetMethodCallHandler(
          [this, i](const Call& call, Reply reply) {
            HandleMedia(i, call, std::move(reply));
          });

      slots_[i].events =
          std::make_unique<flutter::EventChannel<EncodableValue>>(
              registrar->messenger(), name + "/events", codec);
      slots_[i].events->SetStreamHandler(
          std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
              [this, i](const EncodableValue*,
                        std::unique_ptr<flutter::EventSink<EncodableValue>>&&
                            sink)
                  -> std::unique_ptr<
                         flutter::StreamHandlerError<EncodableValue>> {
                slots_[i].sink = std::move(sink);
                return nullptr;
              },
              [this, i](const EncodableValue*)
                  -> std::unique_ptr<
                         flutter::StreamHandlerError<EncodableValue>> {
                slots_[i].sink = nullptr;
                return nullptr;
              }));
    }

    window_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "vyse/webos_window", codec);
    window_->SetMethodCallHandler([this](const Call& call, Reply reply) {
      HandleWindow(call, std::move(reply));
    });

    if (view_ != nullptr) {
      // Asked for as early as there is a window, and again from Dart once the app is up
      // (vyse/webos_window): which of the two the compositor honours is not written down.
      FlutterDesktopViewSetWindowProperty(view_, kWantsBack, "true");
      // The app going behind another and coming back, in Flutter's own words
      // ("AppLifecycleState.resumed"), as LG's embedder says them.
      FlutterDesktopViewAddListener(
          view_, "appLifecycleState",
          [](const std::string& state) {
            if (g_plugin != nullptr) g_plugin->AppStateChanged(state);
          });
    }
  }

  ~VyseWebosPlugin() override {
    for (int i = 0; i < kSlots; ++i) {
      if (slots_[i].loaded && SelectQuietly(i)) NDL_MediaUnload();
      slots_[i].loaded = false;
      slots_[i].sink = nullptr;
    }
    if (g_plugin == this) g_plugin = nullptr;
  }

  // Main loop: hands the waiting events to Dart, oldest first.
  void Drain() {
    std::deque<std::pair<int, std::string>> waiting;
    {
      std::lock_guard<std::mutex> lock(g_queue_mutex);
      g_drain_scheduled = false;
      waiting.swap(g_queue);
    }
    for (const auto& item : waiting) {
      const int slot = item.first;
      if (slot < 0 || slot >= kSlots || !slots_[slot].sink) continue;
      Send(slot, "media", "json", item.second);
    }
  }

  void AppStateChanged(const std::string& state) {
    for (int i = 0; i < kSlots; ++i) {
      if (slots_[i].sink) Send(i, "app", "state", state);
    }
  }

 private:
  // {type: event, name: <name>, data: {<key>: <text>}}: the shape every player of the app
  // sends its events in.
  void Send(int slot, const char* name, const char* key,
            const std::string& text) {
    EncodableMap data;
    data[EncodableValue(std::string(key))] = EncodableValue(text);
    EncodableMap event;
    event[EncodableValue(std::string("type"))] =
        EncodableValue(std::string("event"));
    event[EncodableValue(std::string("name"))] =
        EncodableValue(std::string(name));
    event[EncodableValue(std::string("data"))] = EncodableValue(data);
    slots_[slot].sink->Success(EncodableValue(event));
  }

  // Selects the slot in LG's library; every call below is for "the selected player". A TV
  // whose library has one player only (before webOS 6) has nothing to select: the player is
  // this slot's or it is another's.
  bool SelectQuietly(int slot) {
    if (!HasPlayers()) return holder_ == slot;
    return NDL_MediaSetPlayer(slot) == 0;
  }

  bool Select(int slot, Reply& reply) {
    if (SelectQuietly(slot)) return true;
    if (!HasPlayers()) {
      reply->Error("NO_PLAYER", "The TV's one player is playing something else");
    } else {
      reply->Error("NO_PLAYER", "The TV gave no player: " + LastError());
    }
    return false;
  }

  // On a TV with one player: gives it to this slot. What another slot was playing is
  // unloaded, and its Dart side is told ("taken"), so it shows itself paused and opens its
  // video or song again where it was when it is asked to play.
  void TakeTheOnePlayer(int index) {
    if (holder_ >= 0 && holder_ != index) {
      Slot& other = slots_[holder_];
      if (other.loaded) {
        NDL_MediaUnload();
        other.loaded = false;
        if (other.sink) Send(holder_, "taken", "by", std::to_string(index));
      }
    }
    holder_ = index;
    g_holder.store(index);
  }

  void HandleMedia(int index, const Call& call, Reply reply) {
    Slot& slot = slots_[index];
    const std::string& method = call.method_name();
    const EncodableValue* args = call.arguments();

    if (method == "initialize") {
      slot.owner = IntArg(args, "instanceId", 0);
      reply->Success(EncodableValue(true));
      return;
    }

    // What this TV's media library and compositor have (see the top of the file): the Dart
    // side picks its way by it.
    if (method == "capabilities") {
      EncodableMap has;
      has[EncodableValue(std::string("initWithWindowId"))] =
          EncodableValue(HasInitWithWindowId());
      has[EncodableValue(std::string("players"))] = EncodableValue(HasPlayers());
      has[EncodableValue(std::string("muteDisplay"))] =
          EncodableValue(HasMuteDisplay());
      has[EncodableValue(std::string("displayWindow"))] =
          EncodableValue(HasDisplayWindow());
      has[EncodableValue(std::string("exportedWindows"))] =
          EncodableValue(HasExportedWindows());
      reply->Success(EncodableValue(has));
      return;
    }

    if (method == "dispose") {
      const int64_t who = IntArg(args, "instanceId", 0);
      if (who == slot.owner) {
        if (slot.loaded && SelectQuietly(index)) NDL_MediaUnload();
        slot.loaded = false;
        slot.owner = 0;
      }
      reply->Success();
      return;
    }

    if (method == "load") {
      const std::string uri = TextArg(args, "uri");
      const std::string payload = TextArg(args, "payload");
      const std::string window = TextArg(args, "windowId");
      if (uri.empty()) {
        reply->Error("NO_ADDRESS", "Nothing to open");
        return;
      }
      const bool one_player = !HasPlayers();
      if (one_player) {
        TakeTheOnePlayer(index);
      } else if (!Select(index, reply)) {
        return;
      }
      // (the one player is started once, whichever slot comes first)
      bool& started = one_player ? one_player_started_ : slot.started;
      // An older TV's library takes the window from SDL, at the start and perhaps at each
      // load: VyseTV's stand-in is told which (see UseWindowForOlderLibrary).
      if (!HasInitWithWindowId()) UseWindowForOlderLibrary(window);
      if (!started) {
        // With the window's id for a picture (without one LG's library goes looking for an
        // SDL window, which this app has not); plain for sound alone. A webOS older than 26
        // has only the plain start: there the window's id reaches the TV in the payload alone.
        const int failed = window.empty() || !HasInitWithWindowId()
                               ? NDL_MediaInit(0)
                               : NDL_MediaInitWithWindowId(0, window.c_str());
        if (failed != 0) {
          reply->Error("NO_PLAYER", "The TV's player did not start: " + LastError());
          return;
        }
        if (NDL_MediaSubscribeEvents(one_player ? OnShared : kOnSlot[index]) != 0) {
          std::fprintf(stderr, "[vyse_webos] slot %d: no events: %s\n", index,
                       LastError().c_str());
        }
        started = true;
      } else if (slot.loaded) {
        NDL_MediaUnload();
      }
      slot.loaded = false;
      if (NDL_MediaLoadWithOption(uri.c_str(), payload.c_str()) != 0) {
        reply->Error("LOAD_FAILED", LastError());
        return;
      }
      slot.loaded = true;
      reply->Success();
      return;
    }

    if (method == "unload") {
      if (slot.loaded && SelectQuietly(index)) NDL_MediaUnload();
      slot.loaded = false;
      reply->Success();
      return;
    }

    // Everything below acts on a loaded video. Before there is one there is nothing to do,
    // and that is not an error: Dart asks again once the TV says it has loaded.
    if (!slot.loaded) {
      if (method == "position") {
        reply->Success(EncodableValue(static_cast<int64_t>(-1)));
      } else {
        reply->Success();
      }
      return;
    }
    if (!Select(index, reply)) return;

    int failed = 0;
    if (method == "play") {
      failed = NDL_MediaPlay();
    } else if (method == "pause") {
      failed = NDL_MediaPause();
    } else if (method == "seek") {
      failed = NDL_MediaSeekTo(IntArg(args, "positionMs", 0));
    } else if (method == "setRate") {
      failed = NDL_MediaSetPlaybackRate(NumberArg(args, "rate", 1.0));
    } else if (method == "selectTrack") {
      const std::string type = TextArg(args, "type");
      failed = NDL_MediaSelectTrack(type.c_str(),
                                    static_cast<int>(IntArg(args, "index", 0)));
    } else if (method == "setSubtitleEnable") {
      failed = NDL_MediaSetSubtitleEnable(FlagArg(args, "enable", false));
    } else if (method == "setSubtitleSync") {
      failed = NDL_MediaSetSubtitleSync(static_cast<int>(IntArg(args, "ms", 0)));
    } else if (method == "muteDisplay") {
      // (a TV without it shows the picture until the video is unloaded)
      if (HasMuteDisplay()) failed = NDL_MediaMuteDisplay(FlagArg(args, "mute", false));
    } else if (method == "setDisplayWindow") {
      // Where the picture goes, on a TV that cannot place a window under the app (webOS 4):
      // the media library is told the rectangle itself, in the screen's own pixels. LG's
      // header gives the call a fifth number, "flag", and says nothing of what it means; the
      // TV's older call of the same kind ends in "full screen: yes or no", so it is sent as
      // "no": the rectangle is what is meant. A tester's webOS 4 set has yet to say.
#ifdef VYSE_HAVE_NDL_SET_DISPLAY_WINDOW
      if (HasDisplayWindow()) {
        failed = NDL_MediaSetDisplayWindow(static_cast<int>(IntArg(args, "x", 0)),
                                           static_cast<int>(IntArg(args, "y", 0)),
                                           static_cast<int>(IntArg(args, "w", 0)),
                                           static_cast<int>(IntArg(args, "h", 0)),
                                           static_cast<int>(IntArg(args, "flag", 0)));
      }
#endif
    } else if (method == "position") {
      const long long at = NDL_MediaGetCurrentPosition();
      reply->Success(EncodableValue(static_cast<int64_t>(at)));
      return;
    } else {
      reply->NotImplemented();
      return;
    }

    if (failed != 0) {
      reply->Error("COMMAND_FAILED", method + ": " + LastError());
    } else {
      reply->Success();
    }
  }

  void HandleWindow(const Call& call, Reply reply) {
    if (call.method_name() == "setProperty") {
      const std::string name = TextArg(call.arguments(), "name");
      const std::string value = TextArg(call.arguments(), "value");
      if (view_ == nullptr || name.empty()) {
        reply->Error("NO_WINDOW", "There is no window to set it on");
        return;
      }
      FlutterDesktopViewSetWindowProperty(view_, name.c_str(), value.c_str());
      reply->Success();
      return;
    }
    reply->NotImplemented();
  }

  FlutterDesktopViewRef view_;
  Slot slots_[kSlots];
  // On a TV with one player: the slot that has it, and whether it was started.
  int holder_ = -1;
  bool one_player_started_ = false;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> window_;
};

gboolean DrainOnMainLoop(gpointer) {
  if (g_plugin != nullptr) {
    g_plugin->Drain();
  } else {
    std::lock_guard<std::mutex> lock(g_queue_mutex);
    g_drain_scheduled = false;
    g_queue.clear();
  }
  return G_SOURCE_REMOVE;
}

}  // namespace

void VyseWebosPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter::PluginRegistrar* wrapper =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrar>(registrar);
  wrapper->AddPlugin(std::make_unique<VyseWebosPlugin>(
      wrapper, FlutterDesktopPluginRegistrarGetView(registrar)));
}
