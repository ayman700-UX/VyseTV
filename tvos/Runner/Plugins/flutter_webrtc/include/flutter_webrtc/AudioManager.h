// VyseTV Apple TV copy of flutter_webrtc 1.6.3: made by tool/tvos/vendor_plugins.py, do not edit.
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import "AudioProcessingAdapter.h"

@interface AudioManager : NSObject

@property(nonatomic, strong) RTCDefaultAudioProcessingModule* _Nonnull audioProcessingModule;

@property(nonatomic, strong) AudioProcessingAdapter* _Nonnull capturePostProcessingAdapter;

@property(nonatomic, strong) AudioProcessingAdapter* _Nonnull renderPreProcessingAdapter;

+ (_Nonnull instancetype)sharedInstance;

- (void)addLocalAudioRenderer:(nonnull id<RTCAudioRenderer>)renderer;

- (void)removeLocalAudioRenderer:(nonnull id<RTCAudioRenderer>)renderer;

@end
