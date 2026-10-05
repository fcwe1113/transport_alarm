import 'package:shared_preferences/shared_preferences.dart';

class LocaleSelectionService {
  static const _key = "enabled_locales";
  static const _enabledAtcoCodesKey = "enabled_atco_codes";
  static const _enabledUkRegionsKey = "enabled_uk_regions";
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

  // Future<List<String>> getEnabledAtcoCodes() async {
  //   final prefs = await SharedPreferences.getInstance();
  //   return prefs.getStringList(_enabledAtcoCodesKey) ?? [];
  // }
  //
  // Future<void> setEnabledAtcoCodes(List<String> codes) async {
  //   final prefs = await SharedPreferences.getInstance();
  //   await prefs.setStringList(_enabledAtcoCodesKey, codes);
  // }
  //
  // Future<List<String>> getEnabledUkRegions() async {
  //   final prefs = await SharedPreferences.getInstance();
  //   return prefs.getStringList(_enabledUkRegionsKey) ?? [];
  // }
  //
  // Future<void> setEnabledUkRegions(List<String> regions) async {
  //   final prefs = await SharedPreferences.getInstance();
  //   await prefs.setStringList(_enabledUkRegionsKey, regions);
  // }

  Future<bool> hasCompletedSetup() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key);
  }
}
