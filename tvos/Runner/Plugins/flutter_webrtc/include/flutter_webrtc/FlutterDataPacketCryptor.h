// VyseTV Apple TV copy of flutter_webrtc 1.6.3: made by tool/tvos/vendor_plugins.py, do not edit.
#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#endif

#import <WebRTC/WebRTC.h>

#import "FlutterWebRTCPlugin.h"

@interface FlutterWebRTCPlugin (DataPacketCryptor)

- (void)handleDataPacketCryptorMethodCall:(nonnull FlutterMethodCall*)call
                                   result:(nonnull FlutterResult)result;

@end
