// VyseTV Apple TV copy of flutter_webrtc 1.6.3: made by tool/tvos/vendor_plugins.py, do not edit.
#import "LocalAudioTrack.h"
#import "AudioManager.h"

@implementation LocalAudioTrack {
  RTCAudioTrack* _track;
}

@synthesize audioTrack = _track;

- (instancetype)initWithTrack:(RTCAudioTrack*)track {
  self = [super init];
  if (self) {
    _track = track;
  }
  return self;
}

- (RTCMediaStreamTrack*)track {
  return _track;
}

- (void)addRenderer:(id<RTC_OBJC_TYPE(RTCAudioRenderer)>)renderer {
  [AudioManager.sharedInstance addLocalAudioRenderer:renderer];
}

- (void)removeRenderer:(id<RTC_OBJC_TYPE(RTCAudioRenderer)>)renderer {
  [AudioManager.sharedInstance removeLocalAudioRenderer:renderer];
}

- (void)addProcessing:(_Nonnull id<ExternalAudioProcessingDelegate>)processor {
  [AudioManager.sharedInstance.capturePostProcessingAdapter addProcessing:processor];
}

- (void)removeProcessing:(_Nonnull id<ExternalAudioProcessingDelegate>)processor {
  [AudioManager.sharedInstance.capturePostProcessingAdapter removeProcessing:processor];
}

@end
