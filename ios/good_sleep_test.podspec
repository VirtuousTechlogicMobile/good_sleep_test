#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'good_sleep_test'
  s.version          = '0.1.0'
  s.summary          = 'Classic Good Sleep Test Contec CMS50S plugin'
  s.description      = 'BLE SpO2 session for Good Sleep Test via Contec SDK'
  s.homepage         = 'https://github.com/VirtuousTechlogicMobile/good_sleep_test'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Good Sleep Co' => 'dev@goodslee.co' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.vendored_libraries = 'Frameworks/libContecBluetoothSDK.a'
  s.frameworks = 'CoreBluetooth', 'Foundation'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-force_load $(PODS_TARGET_SRCROOT)/Frameworks/libContecBluetoothSDK.a'
  }
  s.swift_version = '5.0'
end
