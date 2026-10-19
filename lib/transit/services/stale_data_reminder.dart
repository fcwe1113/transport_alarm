import 'package:shared_preferences/shared_preferences.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';

/// Decides when to remind the user on startup that their timetable data is
/// out of date, and remembers when they chose to be reminded later.
class StaleDataReminder {
  static const _snoozedUntilKey = 'stale_reminder_snoozed_until';
  static const snoozeDuration = Duration(days: 1);

  /// False during first-time setup, which downloads data anyway, and while a
  /// snooze is still running.
  Future<bool> shouldRemind() async {
    if (!await LocaleSelectionService().hasCompletedSetup()) return false;
    final prefs = await SharedPreferences.getInstance();
    final snoozedUntil = prefs.getInt(_snoozedUntilKey);
    if (snoozedUntil == null) return true;
    return DateTime.now().millisecondsSinceEpoch >= snoozedUntil;
  }

  Future<void> snooze() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _snoozedUntilKey,
      DateTime.now().add(snoozeDuration).millisecondsSinceEpoch,
    );
  }

  /// Called once data has been refreshed, so the next stale period reminds
  /// straight away instead of waiting out an old snooze.
  Future<void> clearSnooze() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_snoozedUntilKey);
  }
}
