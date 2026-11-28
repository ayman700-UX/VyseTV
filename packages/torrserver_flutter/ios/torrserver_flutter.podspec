Pod::Spec.new do |s|
  s.name             = 'torrserver_flutter'
  s.version          = '0.0.8'
  s.summary          = 'TorrServer Flutter iOS plugin'
  s.description      = <<-DESC
A Flutter package embedding TorrServer in-process on iOS (VyseTV: through the vyse_usenet pod's engine library).
                       DESC
  s.homepage         = 'https://github.com/aymanisthedude26-png/torrserver_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'TorrServer Flutter Contributors' => 'contributors@torrserver.local' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'

  # VyseTV: 15.5, the app's own and the Usenet pod's (this pod depends on it)
  s.platform = :ios, '15.5'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'

  # VyseTV: the engine (TorrServer) is in the Usenet pod's library, the one Go program in the app
  # (packages/vyse_usenet/apple: two Go programs in one app, as 1.0.4 had, are not supported by Go
  # and crashed the Apple TV app). Its entry points are declared by that pod's module.
  s.dependency 'vyse_usenet'
end
