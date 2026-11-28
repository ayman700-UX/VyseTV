Pod::Spec.new do |s|
  s.name             = 'vyse_usenet'
  s.version          = '1.0.0'
  s.summary          = "VyseTV's Usenet engine and torrent engine, linked into the app"
  s.description      = <<-DESC
The Go Usenet engine and the torrent engine (TorrServer) as one static library, one Go program
(VyseUsenet-ios.xcframework, built from ../apple), with the plugin that starts the Usenet engine.
The torrent plugin's pod depends on this one for its engine.
                       DESC
  s.homepage         = 'https://vysetv.cc'
  s.license          = { :file => '../engine/LICENSE' }
  s.author           = 'VyseTV'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/VyseUsenetEngine.h'
  s.dependency 'Flutter'
  s.platform = :ios, '15.5'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }

  # What a Go-built static library links against on iOS
  s.frameworks = 'Foundation', 'Security', 'CoreFoundation', 'SystemConfiguration'
  s.libraries = 'resolv', 'c++'

  # Unpacked from ../binaries/vyse-usenet-ios-arm64.xcframework.zip before the build (the GitHub
  # job does; a local pod is never fetched, so a prepare_command would not run)
  s.vendored_frameworks = 'VyseUsenet-ios.xcframework'
end
