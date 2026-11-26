// VyseTV Apple TV copy of flutter_webrtc 1.6.3: made by tool/tvos/vendor_plugins.py, do not edit.
#import "FlutterRTCDesktopCapturer.h"

// An Apple TV: no screen sharing.
@implementation FlutterWebRTCPlugin (DesktopCapturer)

- (void)getDisplayMedia:(NSDictionary*)constraints result:(FlutterResult)result {
  result([FlutterError errorWithCode:@"getDisplayMediaFailed" message:@"Not on Apple TV" details:nil]);
}

- (void)getDesktopSources:(NSDictionary*)argsMap result:(FlutterResult)result {
  result(@{@"sources" : @[]});
}

- (void)updateDesktopSources:(NSDictionary*)argsMap result:(FlutterResult)result {
  result(@{@"result" : @NO});
}

- (void)getDesktopSourceThumbnail:(NSDictionary*)argsMap result:(FlutterResult)result {
  result([FlutterError errorWithCode:@"getDesktopSourceThumbnailFailed" message:@"Not on Apple TV" details:nil]);
}

@end
