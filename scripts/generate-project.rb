require 'xcodeproj'
root = File.expand_path('../ios', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'HarnessPocket.xcodeproj'))
target = project.new_target(:application, 'HarnessPocket', :ios, '17.0')
group = project.main_group.new_group('HarnessPocket', 'HarnessPocket')
Dir[File.join(root, 'HarnessPocket', '*.swift')].sort.each do |file|
  target.source_build_phase.add_file_reference(group.new_file(File.basename(file)))
end
group.new_file('Info.plist')
group.new_file('HarnessPocket.entitlements')
if Dir.exist?(File.join(root, 'HarnessPocket', 'Assets.xcassets'))
  target.resources_build_phase.add_file_reference(group.new_file('Assets.xcassets'))
end
target.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = '$(POCKET_BUNDLE_ID)'
  config.base_configuration_reference = project.main_group.files.find { |file| file.path == 'Config.xcconfig' } || project.main_group.new_file('Config.xcconfig')
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['CODE_SIGN_ENTITLEMENTS'] = 'HarnessPocket/HarnessPocket.entitlements'
  s['INFOPLIST_FILE'] = 'HarnessPocket/Info.plist'
  s['SWIFT_VERSION'] = '5.0'
  s['TARGETED_DEVICE_FAMILY'] = '1'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  s['MARKETING_VERSION'] = '0.1.0'
  s['CURRENT_PROJECT_VERSION'] = '7'
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  s['APNS_ENTITLEMENT'] = config.name == 'Debug' ? 'development' : 'production'
  s['APNS_ENVIRONMENT'] = config.name == 'Debug' ? 'sandbox' : 'production'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
end
project.root_object.attributes['TargetAttributes'] = {target.uuid => {'SystemCapabilities' => {'com.apple.Push' => {'enabled' => 1}}}}
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(File.join(root, 'HarnessPocket.xcodeproj'), 'HarnessPocket', true)
puts File.join(root, 'HarnessPocket.xcodeproj')
