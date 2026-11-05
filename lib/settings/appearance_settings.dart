import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One of the colours the app's theme can be built from.
typedef ThemeSeed = ({String key, Color color});

/// The colours offered in Appearance settings. Saved by key, so a colour
/// can be adjusted without losing anyone's choice.
const List<ThemeSeed> themeSeeds = [
  (key: 'purple', color: Colors.deepPurple),
  (key: 'indigo', color: Colors.indigo),
  (key: 'blue', color: Colors.blue),
  (key: 'teal', color: Colors.teal),
  (key: 'green', color: Colors.green),
  (key: 'amber', color: Colors.amber),
  (key: 'orange', color: Colors.deepOrange),
  (key: 'red', color: Colors.red),
  (key: 'pink', color: Colors.pink),
  (key: 'brown', color: Colors.brown),
];

/// The light/dark mode and theme colour the user picked.
class AppearanceSettings {
  final ThemeMode themeMode;
  final String seedKey;

  const AppearanceSettings({this.themeMode = ThemeMode.system, this.seedKey = 'purple'});

  /// The picked colour, or the first one if the saved key is no longer offered.
  Color get seedColor =>
      themeSeeds.firstWhere((seed) => seed.key == seedKey, orElse: () => themeSeeds.first).color;

  ColorScheme scheme(Brightness brightness) =>
      ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
}

/// Holds the appearance so settings can update MaterialApp live.
final ValueNotifier<AppearanceSettings> appearanceNotifier = ValueNotifier(const AppearanceSettings());

const _themeModeKey = 'appearance_theme_mode';
const _seedKey = 'appearance_seed';

/// Reads the saved appearance into [appearanceNotifier], at startup.
Future<void> loadAppearance() async {
  final prefs = await SharedPreferences.getInstance();
  appearanceNotifier.value = AppearanceSettings(
    themeMode: ThemeMode.values.asNameMap()[prefs.getString(_themeModeKey)] ?? ThemeMode.system,
    seedKey: prefs.getString(_seedKey) ?? 'purple',
  );
}

Future<void> setThemeMode(ThemeMode mode) async {
  appearanceNotifier.value = AppearanceSettings(themeMode: mode, seedKey: appearanceNotifier.value.seedKey);
  await (await SharedPreferences.getInstance()).setString(_themeModeKey, mode.name);
}

Future<void> setThemeSeed(String key) async {
  appearanceNotifier.value = AppearanceSettings(themeMode: appearanceNotifier.value.themeMode, seedKey: key);
  await (await SharedPreferences.getInstance()).setString(_seedKey, key);
}
