Pod::Spec.new do |s|
  s.name             = 'vyse_usenet'
  s.version          = '1.0.0'
  s.summary          = "VyseTV's Usenet engine for macOS"
  s.description      = <<-DESC
The Go Usenet engine as a program in the app bundle (Intel and Apple silicon), started by the app.
                       DESC
  s.homepage         = 'https://vysetv.cc'
  s.license          = { :file => '../engine/LICENSE' }
  s.author           = 'VyseTV'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  # bin/vyse-usenet is unpacked from ../binaries/vyse-usenet-darwin-universal.zip, made runnable
  # and signed ad hoc before the build (the GitHub job does); it lands in this pod's framework's
  # Resources, where the app finds it.
  s.resources = ['bin/vyse-usenet']
end
