// Copyright 2022 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Changed for VyseTV (tool/tizen/avplay/README.md): see the lines marked "VyseTV".

#include "video_player.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include "log.h"

namespace video_player_avplay_tizen {

static int64_t player_index = 1;

VideoPlayer::VideoPlayer(flutter::BinaryMessenger *messenger,
                         FlutterDesktopViewRef flutter_view)
    : binary_messenger_(messenger), flutter_view_(flutter_view) {}

VideoPlayer::~VideoPlayer() {
  StopReadyWatch();  // VyseTV
  std::lock_guard<std::mutex> lock(queue_mutex_);
  if (sink_event_source_) {
    g_source_remove(sink_event_source_);
  }
}

void VideoPlayer::ClearUpEventChannel() {
  StopReadyWatch();  // VyseTV
  is_initialized_ = false;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    event_sink_ = nullptr;
  }
  if (event_channel_) {
    event_channel_->SetStreamHandler(nullptr);
  }
}

int64_t VideoPlayer::SetUpEventChannel() {
  int64_t player_id = player_index++;
  std::string channel_name =
      "tizen/video_player/video_events_" + std::to_string(player_id);
  auto channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          binary_messenger_, channel_name,
          &flutter::StandardMethodCodec::GetInstance());
  auto handler = std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [&](const flutter::EncodableValue *arguments,
          std::unique_ptr<flutter::EventSink<>> &&events)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        event_sink_ = std::move(events);
        if (IsReady()) {
          SendInitialized();
        } else {
          LOG_INFO("[VideoPlayer] Player is not ready.");
        }
        return nullptr;
      },
      [&](const flutter::EncodableValue *arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        event_sink_ = nullptr;
        return nullptr;
      });
  channel->SetStreamHandler(std::move(handler));
  event_channel_ = std::move(channel);
  StartReadyWatch();  // VyseTV
  return player_id;
}

void VideoPlayer::ExecuteSinkEvents() {
  std::lock_guard<std::mutex> lock(queue_mutex_);
  sink_event_source_ = 0;
  while (!encodable_event_queue_.empty()) {
    if (event_sink_) {
      event_sink_->Success(encodable_event_queue_.front());
    }
    encodable_event_queue_.pop();
  }

  while (!error_event_queue_.empty()) {
    if (event_sink_) {
      event_sink_->Error(error_event_queue_.front().first,
                         error_event_queue_.front().second);
    }
    error_event_queue_.pop();
  }
}

void VideoPlayer::RequestEventDispatch() {
  if (sink_event_source_ == 0) {
    sink_event_source_ = g_idle_add_full(
        G_PRIORITY_DEFAULT,
        [](gpointer data) -> gboolean {
          auto *self = static_cast<VideoPlayer *>(data);
          self->ExecuteSinkEvents();
          return G_SOURCE_REMOVE;
        },
        this, nullptr);
  }
}

void VideoPlayer::PushEvent(flutter::EncodableValue encodable_value) {
  std::lock_guard<std::mutex> lock(queue_mutex_);
  if (event_sink_ == nullptr) {
    LOG_ERROR("[VideoPlayer] event sink is nullptr.");
    return;
  }
  encodable_event_queue_.push(encodable_value);
  RequestEventDispatch();
}

// VyseTV: see video_player.h.
void VideoPlayer::StartReadyWatch() {
  StopReadyWatch();
  ready_watch_ticks_ = 0;
  ready_seen_ticks_ = 0;
  prepare_error_sent_ = false;
  ready_watch_source_ = g_timeout_add(400, OnReadyWatch, this);
}

void VideoPlayer::StopReadyWatch() {
  if (ready_watch_source_) {
    g_source_remove(ready_watch_source_);
    ready_watch_source_ = 0;
  }
}

gboolean VideoPlayer::OnReadyWatch(gpointer data) {
  auto *self = static_cast<VideoPlayer *>(data);
  bool listening;
  {
    std::lock_guard<std::mutex> lock(self->queue_mutex_);
    listening = self->event_sink_ != nullptr;
  }
  if (self->is_initialized_) {
    self->ready_watch_source_ = 0;
    return G_SOURCE_REMOVE;
  }
  if (self->prepare_failed_.load()) {
    if (!listening) return G_SOURCE_CONTINUE;  // said once the app listens
    if (!self->prepare_error_sent_) {
      self->prepare_error_sent_ = true;
      LOG_ERROR("[VideoPlayer] Preparation failed: telling the app.");
      self->SendError("PrepareFailed",
                      "The TV's player could not prepare the video.");
    }
    self->ready_watch_source_ = 0;
    return G_SOURCE_REMOVE;
  }
  // READY on two looks in a row (800 ms) with no callback: the player is ready, say so. (One
  // look could race the callback, which comes on the player's own thread.)
  if (self->IsReady()) {
    if (++self->ready_seen_ticks_ >= 2 && listening) {
      LOG_INFO("[VideoPlayer] Ready without its callback: telling the app.");
      self->SendInitialized();
    }
  } else {
    self->ready_seen_ticks_ = 0;
  }
  if (++self->ready_watch_ticks_ >= 50) {
    self->ready_watch_source_ = 0;
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

void VideoPlayer::SendInitialized() {
  if (!is_initialized_ && event_sink_) {
    int32_t width = 0, height = 0;
    GetVideoSize(&width, &height);
    is_initialized_ = true;
    auto duration = GetDuration();
    flutter::EncodableList duration_range{
        flutter::EncodableValue(duration.first),
        flutter::EncodableValue(duration.second)};

    flutter::EncodableMap result = {
        {flutter::EncodableValue("event"),
         flutter::EncodableValue("initialized")},
        {flutter::EncodableValue("duration"),
         flutter::EncodableValue(duration_range)},
        {flutter::EncodableValue("width"), flutter::EncodableValue(width)},
        {flutter::EncodableValue("height"), flutter::EncodableValue(height)},
    };
    PushEvent(flutter::EncodableValue(result));
  }
}

void VideoPlayer::SendBufferingStart() {
  flutter::EncodableMap result = {
      {flutter::EncodableValue("event"),
       flutter::EncodableValue("bufferingStart")},
  };
  PushEvent(flutter::EncodableValue(result));
}

void VideoPlayer::SendBufferingUpdate(int32_t value) {
  flutter::EncodableMap result = {
      {flutter::EncodableValue("event"),
       flutter::EncodableValue("bufferingUpdate")},
      {flutter::EncodableValue("value"), flutter::EncodableValue(value)},
  };
  PushEvent(flutter::EncodableValue(result));
}

void VideoPlayer::SendBufferingEnd() {
  flutter::EncodableMap result = {
      {flutter::EncodableValue("event"),
       flutter::EncodableValue("bufferingEnd")},
  };
  PushEvent(flutter::EncodableValue(result));
}

void VideoPlayer::SendSeekCompleted() {
  flutter::EncodableMap result = {
      {flutter::EncodableValue("event"),
       flutter::EncodableValue("seekCompleted")},
  };
  PushEvent(flutter::EncodableValue(result));
}

void VideoPlayer::SendSubtitleUpdate(int32_t duration,
                                     flutter::EncodableList texts_info,
                                     flutter::EncodableMap picture_info) {
  flutter::EncodableMap result = {
      {flutter::EncodableValue("event"),
       flutter::EncodableValue("subtitleUpdate")},
      {flutter::EncodableValue("duration"), flutter::EncodableValue(duration)},
      {flutter::EncodableValue("textsInfo"),
       flutter::EncodableValue(texts_info)},
      {flutter::EncodableValue("pictureInfo"),
       flutter::EncodableValue(picture_info)},
  };

  PushEvent(flutter::EncodableValue(result));
}

void VideoPlayer::SendPlayCompleted() {
  flutter::EncodableMap result = {
      {flutter::EncodableValue("event"), flutter::EncodableValue("completed")},
  };
  PushEvent(flutter::EncodableValue(result));
}

void VideoPlayer::SendIsPlayingState(bool is_playing) {
  flutter::EncodableMap result = {
      {flutter::EncodableValue("event"),
       flutter::EncodableValue("isPlayingStateUpdate")},
      {flutter::EncodableValue("isPlaying"),
       flutter::EncodableValue(is_playing)},
  };
  PushEvent(flutter::EncodableValue(result));
}

void VideoPlayer::SendRestored() {
  if (is_restored_ && event_sink_) {
    is_restored_ = false;
    int32_t width = 0, height = 0;
    GetVideoSize(&width, &height);
    auto duration = GetDuration();
    flutter::EncodableList duration_range{
        flutter::EncodableValue(duration.first),
        flutter::EncodableValue(duration.second)};

    flutter::EncodableMap result = {
        {flutter::EncodableValue("event"), flutter::EncodableValue("restored")},
        {flutter::EncodableValue("duration"),
         flutter::EncodableValue(duration_range)},
        {flutter::EncodableValue("width"), flutter::EncodableValue(width)},
        {flutter::EncodableValue("height"), flutter::EncodableValue(height)},
    };
    PushEvent(flutter::EncodableValue(result));
  }
}

void VideoPlayer::SendADFromDash(flutter::EncodableMap ad_info) {
  flutter::EncodableMap result = {
      {flutter::EncodableValue("event"), flutter::EncodableValue("adFromDash")},
      {flutter::EncodableValue("adInfo"), flutter::EncodableValue(ad_info)},
  };
  PushEvent(flutter::EncodableValue(result));
}

void VideoPlayer::SendManifestInfo(std::string manifest_info) {
  flutter::EncodableMap result = {
      {flutter::EncodableValue("event"),
       flutter::EncodableValue("manifestInfoUpdated")},
      {flutter::EncodableValue("manifestInfo"),
       flutter::EncodableValue(manifest_info)},
  };
  PushEvent(flutter::EncodableValue(result));
}

void VideoPlayer::SendError(const std::string &error_code,
                            const std::string &error_message) {
  std::lock_guard<std::mutex> lock(queue_mutex_);
  if (event_sink_) {
    error_event_queue_.push(std::make_pair(error_code, error_message));
    RequestEventDispatch();
  }
}

void *VideoPlayer::GetWindowHandle() {
  return FlutterDesktopViewGetNativeHandle(flutter_view_);
}

}  // namespace video_player_avplay_tizen
