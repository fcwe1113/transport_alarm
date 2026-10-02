require "xcodeproj"

TEAM_ID = "66RCG95DR7"

project = Xcodeproj::Project.open("ios/Runner.xcodeproj")

targets = project.targets.select do |target|
  ["Runner", "NotificationService"].include?(target.name)
end

targets.each do |target|
  target.build_configurations.each do |config|
    config.build_settings["DEVELOPMENT_TEAM"] = TEAM_ID
  end
end

extension = project.targets.find do |target|
  target.name == "NotificationService"
end

abort "NotificationService target not found" unless extension

extension.build_configurations.each do |config|
    config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] =
        "$(PRODUCT_BUNDLE_IDENTIFIER).NotificationService"

      config.build_settings["INFOPLIST_FILE"] =
        "NotificationService/Info.plist"

  config.build_settings["DEVELOPMENT_TEAM"] = TEAM_ID
  config.build_settings["CODE_SIGN_STYLE"] = "Manual"
  config.build_settings["CODE_SIGN_IDENTITY"] = "Apple Distribution"
#   config.build_settings["PROVISIONING_PROFILE_SPECIFIER"] =
#     "TransportAlarmNotificationExtensionProfile"
    config.build_settings["CODE_SIGN_ENTITLEMENTS"] = ""
end

runner = project.targets.find { |target| target.name == "Runner" }

runner.build_configurations.each do |config|
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] =
    "Runner/Runner.entitlements"

  config.build_settings["DEVELOPMENT_TEAM"] = TEAM_ID
  config.build_settings["CODE_SIGN_STYLE"] = "Manual"
  config.build_settings["CODE_SIGN_IDENTITY"] = "Apple Distribution"
#   config.build_settings["PROVISIONING_PROFILE_SPECIFIER"] =
#     "Transport Alarm"
end

project.save
puts "Signing settings updated."