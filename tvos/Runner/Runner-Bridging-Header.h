// The Objective-C the app's Swift calls. On an iPhone flutter_webrtc is a module of its own that
// livekit_client imports; on Apple TV both are compiled into the app (tool/tvos/vendor_plugins.py),
// and flutter_webrtc's classes reach livekit_client's Swift and the AppDelegate through here.
#import <WebRTC/WebRTC.h>

#import "FlutterWebRTCPlugin.h"
#import "LocalTrack.h"
#import "LocalAudioTrack.h"
#import "AudioProcessingAdapter.h"
#import "AudioManager.h"

// The engines linked into the app (VyseUsenet-tvos.xcframework: the Usenet engine and the torrent
// engine in one Go library): their C entry points, called by
// packages/vyse_usenet/ios/Classes/VyseUsenetPlugin.swift and
// packages/torrserver_flutter/ios/Classes/TorrserverFlutterPlugin.swift
#import "../../packages/vyse_usenet/ios/Classes/VyseUsenetEngine.h"
