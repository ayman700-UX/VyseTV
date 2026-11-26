// VyseTV Apple TV copy of flutter_webrtc 1.6.3: made by tool/tvos/vendor_plugins.py, do not edit.
#import "FlutterRTCVideoPlatformTypes.h"

#define FlutterRTCVideoPlatformViewFactoryID @"rtc_video_platform_view"

@class FlutterRTCVideoPlatformViewController;

@interface FlutterRTCVideoPlatformViewFactory : NSObject <FlutterPlatformViewFactory>

@property(nonatomic, strong) NSObject<FlutterBinaryMessenger>* _Nonnull messenger;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber*, FlutterRTCVideoPlatformViewController*>* _Nullable renders;

- (_Nonnull instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger>* _Nonnull)messenger;

@end
