// VyseTV Apple TV copy of flutter_webrtc 1.6.3: made by tool/tvos/vendor_plugins.py, do not edit.
#import <WebRTC/WebRTC.h>
#import "LocalTrack.h"
#import "VideoProcessingAdapter.h"

@interface LocalVideoTrack : NSObject <LocalTrack>

- (_Nonnull instancetype)initWithTrack:(RTCVideoTrack* _Nonnull)track;

- (_Nonnull instancetype)initWithTrack:(RTCVideoTrack* _Nonnull)track
                       videoProcessing:(VideoProcessingAdapter* _Nullable)processing;

@property(nonatomic, strong) RTCVideoTrack* _Nonnull videoTrack;

@property(nonatomic, strong) VideoProcessingAdapter* _Nonnull processing;

- (void)addRenderer:(_Nonnull id<RTC_OBJC_TYPE(RTCVideoRenderer)>)renderer;

- (void)removeRenderer:(_Nonnull id<RTC_OBJC_TYPE(RTCVideoRenderer)>)renderer;

- (void)addProcessing:(_Nonnull id<ExternalVideoProcessingDelegate>)processor;

- (void)removeProcessing:(_Nonnull id<ExternalVideoProcessingDelegate>)processor;

@end
