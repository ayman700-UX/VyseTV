// VyseTV Apple TV copy of flutter_webrtc 1.6.3: made by tool/tvos/vendor_plugins.py, do not edit.
#import "CameraUtils.h"

// An Apple TV: no camera controls (a TV in VyseTV never sends video).
static FlutterError* VyseNoCamera(NSString* code) {
  return [FlutterError errorWithCode:code message:@"Not on Apple TV" details:nil];
}

@implementation FlutterWebRTCPlugin (CameraUtils)

- (void)mediaStreamTrackHasTorch:(RTCMediaStreamTrack*)track result:(FlutterResult)result {
  result(@NO);
}

- (void)mediaStreamTrackSetTorch:(RTCMediaStreamTrack*)track torch:(BOOL)torch result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetTorchFailed"));
}

- (void)mediaStreamTrackSetZoom:(RTCMediaStreamTrack*)track zoomLevel:(double)zoomLevel result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetZoomFailed"));
}

- (void)mediaStreamTrackSetFocusMode:(RTCMediaStreamTrack*)track focusMode:(NSString*)focusMode result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetFocusModeFailed"));
}

- (void)mediaStreamTrackSetFocusPoint:(RTCMediaStreamTrack*)track focusPoint:(NSDictionary*)focusPoint result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetFocusPointFailed"));
}

- (void)mediaStreamTrackSetExposureMode:(RTCMediaStreamTrack*)track exposureMode:(NSString*)exposureMode result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetExposureModeFailed"));
}

- (void)mediaStreamTrackSetExposurePoint:(RTCMediaStreamTrack*)track exposurePoint:(NSDictionary*)exposurePoint result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSetExposurePointFailed"));
}

- (void)mediaStreamTrackSwitchCamera:(RTCMediaStreamTrack*)track result:(FlutterResult)result {
  result(VyseNoCamera(@"mediaStreamTrackSwitchCameraFailed"));
}

- (NSInteger)selectFpsForFormat:(AVCaptureDeviceFormat*)format targetFps:(NSInteger)targetFps {
  return targetFps;
}

- (AVCaptureDeviceFormat*)selectFormatForDevice:(AVCaptureDevice*)device targetWidth:(NSInteger)targetWidth targetHeight:(NSInteger)targetHeight {
  return nil;
}

- (AVCaptureDevice*)findDeviceForPosition:(AVCaptureDevicePosition)position {
  return nil;
}

@end
