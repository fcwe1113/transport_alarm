import 'package:flutter/services.dart';

/// The iOS notification settings alarms rely on.
class IosNotificationStatus {
  /// Notifications are allowed for the app.
  final bool authorized;

  /// Time-sensitive notifications, which can break through Focus modes, are
  /// allowed. Null when iOS can't tell.
  final bool? timeSensitive;

  const IosNotificationStatus({required this.authorized, required this.timeSensitive});
}

/// iOS only: reads the app's notification settings and opens them in the
/// Settings app.
class IosSettingsService {
  static const _channel = MethodChannel('com.fcwe1113.transport_alarm/ios_settings');

  static Future<IosNotificationStatus> notificationStatus() async {
    final settings = await _channel.invokeMapMethod<String, Object?>('notificationSettings') ?? const {};
    return IosNotificationStatus(
      authorized: settings['authorized'] == true,
      timeSensitive: switch (settings['timeSensitive']) {
        'enabled' => true,
        'disabled' => false,
        _ => null,
      },
    );
  }

  /// Opens the app's notification settings, or its settings page on iOS
  /// versions without a direct link. False if it couldn't be opened.
  static Future<bool> openNotificationSettings() async =>
      await _channel.invokeMethod<bool>('openNotificationSettings') ?? false;
}
