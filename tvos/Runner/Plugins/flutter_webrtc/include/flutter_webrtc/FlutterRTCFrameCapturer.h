// VyseTV Apple TV copy of flutter_webrtc 1.6.3: made by tool/tvos/vendor_plugins.py, do not edit.
#import <WebRTC/WebRTC.h>

#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#endif

@interface FlutterRTCFrameCapturer : NSObject <RTCVideoRenderer>

- (instancetype)initWithTrack:(RTCVideoTrack*)track
                       toPath:(NSString*)path
                       result:(FlutterResult)result;

+ (CVPixelBufferRef)convertToCVPixelBuffer:(RTCVideoFrame *) frame;

@end
