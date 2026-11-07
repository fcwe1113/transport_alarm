import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transport_alarm/settings/advanced_settings.dart';
import 'package:transport_alarm/settings/appearance_settings.dart';
import 'package:transport_alarm/transit/services/staleness_tracker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AdvancedSettings.resetToDefaults();
  });

  group('AdvancedSettings', () {
    test('uses the defaults until set', () {
      expect(AdvancedSettings.value(AdvancedSettings.parallelRequests), 20);
      expect(AdvancedSettings.refreshInterval, const Duration(days: 7));
    });

    test('keeps a value that was set, across a reload', () async {
      await AdvancedSettings.set(AdvancedSettings.refreshIntervalDays, 3);
      expect(AdvancedSettings.refreshInterval, const Duration(days: 3));
      await AdvancedSettings.load();
      expect(AdvancedSettings.value(AdvancedSettings.refreshIntervalDays), 3);
    });

    test('refuses a value that isn\'t one of the choices', () {
      expect(() => AdvancedSettings.set(AdvancedSettings.parallelRequests, 7), throwsArgumentError);
    });

    test('ignores a saved value that is no longer a choice', () async {
      SharedPreferences.setMockInitialValues({AdvancedSettings.checkLeadMinutes.key: 11});
      await AdvancedSettings.load();
      expect(AdvancedSettings.value(AdvancedSettings.checkLeadMinutes), 10);
    });

    test('reset brings back every default', () async {
      await AdvancedSettings.set(AdvancedSettings.checkLeadMinutes, 30);
      await AdvancedSettings.resetToDefaults();
      expect(AdvancedSettings.value(AdvancedSettings.checkLeadMinutes), 10);
      expect((await SharedPreferences.getInstance()).containsKey(AdvancedSettings.checkLeadMinutes.key), isFalse);
    });
  });

  group('AppearanceSettings', () {
    test('defaults to following the system, in purple', () async {
      await loadAppearance();
      expect(appearanceNotifier.value.themeMode, ThemeMode.system);
      expect(appearanceNotifier.value.seedColor, Colors.deepPurple);
    });

    test('saves the theme and colour, and reads them back', () async {
      await setThemeMode(ThemeMode.dark);
      await setThemeSeed('teal');
      appearanceNotifier.value = const AppearanceSettings();
      await loadAppearance();
      expect(appearanceNotifier.value.themeMode, ThemeMode.dark);
      expect(appearanceNotifier.value.seedColor, Colors.teal);
    });

    test('falls back to the first colour for a key no longer offered', () {
      expect(const AppearanceSettings(seedKey: 'gone').seedColor, themeSeeds.first.color);
    });

    test('every colour has a distinct key', () {
      expect(themeSeeds.map((seed) => seed.key).toSet(), hasLength(themeSeeds.length));
    });
  });

  group('StalenessTracker', () {
    final tracker = StalenessTracker();

    test('is stale with no record of a refresh', () async {
      expect(await tracker.isStale('gb', 'gtfs'), isTrue);
    });

    test('is fresh right after a refresh, and stale once older than the interval', () async {
      await tracker.markRefreshed('gb', 'gtfs');
      expect(await tracker.isStale('gb', 'gtfs'), isFalse);
      expect(await tracker.isStale('gb', 'gtfs', maxAge: Duration.zero), isTrue);
    });

    test('is stale when what was refreshed changed (GB areas)', () async {
      await tracker.markRefreshed('gb', 'gtfs', signature: 'E06000008');
      expect(await tracker.isStale('gb', 'gtfs', signature: 'E06000008'), isFalse);
      expect(await tracker.isStale('gb', 'gtfs', signature: 'E06000008,E08000001'), isTrue);
    });

    test('forgetting a region clears only its records', () async {
      await tracker.markRefreshed('gb', 'gtfs');
      await tracker.markRefreshed('hk', 'kmb');
      await tracker.forgetLocale('gb');
      expect(await tracker.lastRefreshed('gb', 'gtfs'), isNull);
      expect(await tracker.lastRefreshed('hk', 'kmb'), isNotNull);
    });
  });
}
