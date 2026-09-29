require "xcodeproj"

project_path = "ios/Runner.xcodeproj"
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |target| target.name == "Runner" }

abort "Runner target not found" unless app_target
abort "NotificationService already exists" if project.targets.any? { |target| target.name == "NotificationService" }

group = project.main_group.new_group(
  "NotificationService",
  "NotificationService",
  :group
)

swift_file = group.new_file("NotificationService.swift")
plist_file = group.new_file("Info.plist")

extension_target = project.new_target(
  :app_extension,
  "NotificationService",
  :ios,
  "13.0"
)

extension_target.product_name = "NotificationService"
extension_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] =
    "$(PRODUCT_BUNDLE_IDENTIFIER).NotificationService"

  config.build_settings["INFOPLIST_FILE"] =
    "NotificationService/Info.plist"

  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "13.0"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
end

extension_target.source_build_phase.add_file_reference(swift_file)

resources_phase = extension_target.resources_build_phase
resources_phase.add_file_reference(plist_file)

embed_phase = app_target.copy_files_build_phases.find do |phase|
  phase.dst_subfolder_spec == "13"
end

unless embed_phase
  embed_phase = app_target.new_copy_files_build_phase(
    "Embed Foundation Extensions"
  )

  # Xcode's PlugIns directory.
  embed_phase.dst_subfolder_spec = "13"
end

build_file = embed_phase.add_file_reference(extension_target.product_reference)
build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

app_target.add_dependency(extension_target)

project.save
puts "NotificationService target added."
