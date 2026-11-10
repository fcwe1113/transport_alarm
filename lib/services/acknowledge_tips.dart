import 'package:shared_preferences/shared_preferences.dart';
import 'package:transport_alarm/services/app_group_storage.dart';

/// Android: whether to show the hints that the ring notification's
/// Acknowledge button works without opening the app. Shown until the user
/// first uses it. iOS keeps its own flag in the App Group instead, see
/// [AppGroupStorage.takeAcknowledgeTip].
class AcknowledgeTips {
  static const _usedButtonKey = 'acknowledged_from_notification';

  /// Whether the user has acknowledged from the notification. Reloaded, as
  /// the button is handled in a background isolate.
  static Future<bool> usedNotificationButton() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(_usedButtonKey) ?? false;
  }

  static Future<void> markUsedNotificationButton() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_usedButtonKey, true);
  }
}
