// VyseTV Apple TV copy of flutter_webrtc 1.6.3: made by tool/tvos/vendor_plugins.py, do not edit.
#ifndef FlutterRTCVideoPlatformTypes_h
#define FlutterRTCVideoPlatformTypes_h

#import <TargetConditionals.h>

#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
typedef UIView FlutterRTCVideoPlatformNativeView;
typedef CGRect FlutterRTCVideoPlatformFrame;
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
typedef NSView FlutterRTCVideoPlatformNativeView;
typedef NSRect FlutterRTCVideoPlatformFrame;
#endif

#endif /* FlutterRTCVideoPlatformTypes_h */
