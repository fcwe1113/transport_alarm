import 'package:shared_preferences/shared_preferences.dart';

/// One advanced setting: its default and the values it can be set to, so a
/// saved value is always one of [choices].
class AdvancedSetting {
  final String key;
  final int defaultValue;
  final List<int> choices;

  const AdvancedSetting(this.key, this.defaultValue, this.choices);
}

/// Tuning for downloads and data freshness, set in Settings → Advanced.
/// Loaded once at startup and read synchronously by the code it tunes.
/// Background isolates (Android alarm checks) never download, so they use
/// the defaults.
class AdvancedSettings {
  /// Operator API requests sent at a time while refreshing route and stop
  /// data (ApiCaller.callBatch).
  static const parallelRequests = AdvancedSetting('advanced_parallel_requests', 20, [5, 10, 20, 30, 50]);

  /// stop_times.txt rows read per batch, and so per database commit, during
  /// a timetable import.
  static const timetableRowsPerCommit = AdvancedSetting(
    'advanced_timetable_rows_per_commit',
    25000,
    [5000, 10000, 25000, 50000, 100000],
  );

  /// Days before downloaded data counts as out of date.
  static const refreshIntervalDays = AdvancedSetting('advanced_refresh_interval_days', 7, [1, 3, 7, 14, 30]);

  static const all = [parallelRequests, timetableRowsPerCommit, refreshIntervalDays];

  static final Map<String, int> _values = {};

  /// The current value of [setting].
  static int value(AdvancedSetting setting) => _values[setting.key] ?? setting.defaultValue;

  /// How long before downloaded data counts as out of date.
  static Duration get refreshInterval => Duration(days: value(refreshIntervalDays));

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final setting in all) {
      final saved = prefs.getInt(setting.key);
      if (saved != null && setting.choices.contains(saved)) _values[setting.key] = saved;
    }
  }

  static Future<void> set(AdvancedSetting setting, int value) async {
    if (!setting.choices.contains(value)) throw ArgumentError.value(value, setting.key);
    _values[setting.key] = value;
    await (await SharedPreferences.getInstance()).setInt(setting.key, value);
  }

  static Future<void> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    for (final setting in all) {
      _values.remove(setting.key);
      await prefs.remove(setting.key);
    }
  }
}
