import 'package:shared_preferences/shared_preferences.dart';

class LocaleSelectionService {
  static const _key = "enabled_locales";
  static const _appLanguageKey = "app_language_code";

  Future<String> getAppLanguageCode() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_appLanguageKey);
    if (code != null && code.isNotEmpty) return code;
    await prefs.setString(_appLanguageKey, 'en');
    return 'en';
  }

  Future<void> setAppLanguageCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appLanguageKey, code);
  }

  Future<List<String>> getEnabledLocales() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? [];
  }

  Future<void> setEnabledLocales(List<String> codes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, codes);
  }

  Future<bool> hasCompletedSetup() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key);
  }
}
