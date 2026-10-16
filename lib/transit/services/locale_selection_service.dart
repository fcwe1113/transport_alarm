import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocaleSelectionService {
  static const _key = "enabled_locales";
  // static const _enabledUkRegionsKey = "enabled_uk_regions";
  static const _appLanguageKey = "app_language_code";
  static Map<String, String>? _localeSelectionDraft;
  static final ValueNotifier<Map<String, String>> _draftNotifier =
      ValueNotifier<Map<String, String>>(<String, String>{});

  static ValueListenable<Map<String, String>>
      get localeSelectionDraftListenable => _draftNotifier;

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

  Future<Map<String, String>> getEnabledLocales() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLocales = prefs.getStringList(_key) ?? const <String>[];
    final locales = <String, String>{};
    for (final savedLocale in savedLocales) {
      try {
        locales.addAll(_decodeLocale(savedLocale));
      } on FormatException {
        // Ignore malformed stored entries so one bad value does not prevent
        // the rest of the saved locale selection from loading.
      }
    }
    return locales;
  }

  Future<void> setEnabledLocales(Map<String, String> locales) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      locales.entries
          .map((entry) => jsonEncode({entry.key: entry.value}))
          .toList(),
    );
  }

  /// Starts an editable in-memory locale selection copied from saved settings.
  Future<Map<String, String>> beginLocaleSelectionDraft() async {
    _localeSelectionDraft = await getEnabledLocales();
    _draftNotifier.value = Map<String, String>.from(_localeSelectionDraft!);
    return Map<String, String>.from(_localeSelectionDraft!);
  }

  /// Returns the current draft, or the saved selection when no draft is open.
  Future<Map<String, String>> getLocaleSelectionDraft() async {
    _localeSelectionDraft ??= await getEnabledLocales();
    return Map<String, String>.from(_localeSelectionDraft!);
  }

  /// Updates only the in-memory draft; preferences are unchanged until commit.
  void setLocaleSelectionDraft(Map<String, String> locales) {
    _localeSelectionDraft = Map<String, String>.from(locales);
    _draftNotifier.value = Map<String, String>.from(_localeSelectionDraft!);
  }

  /// Adds or removes one locale entry without writing persistent preferences.
  void updateLocaleSelectionDraftEntry(String code, String? value) {
    _localeSelectionDraft ??= <String, String>{};
    if (value == null) {
      _localeSelectionDraft!.remove(code);
    } else {
      _localeSelectionDraft![code] = value;
    }
    _draftNotifier.value = Map<String, String>.from(_localeSelectionDraft!);
  }

  /// Persists the current draft after the user confirms the locale screen.
  Future<void> commitLocaleSelectionDraft() async {
    final draft = _localeSelectionDraft;
    if (draft == null) return;
    await setEnabledLocales(draft);
    _localeSelectionDraft = null;
    _draftNotifier.value = <String, String>{};
  }

  Map<String, String> _decodeLocale(String savedLocale) {
    try {
      final decoded = jsonDecode(savedLocale);
      if (decoded is Map<String, dynamic> &&
          decoded.keys.every((key) => decoded[key] is String)) {
        return decoded.map((key, value) => MapEntry(key, value as String));
      }
    } on FormatException {
      // Older builds stored Dart's Map.toString() output, which is not JSON.
    }

    // Read legacy values such as `{code: hk, displayName: Hong Kong}`.
    final value = savedLocale.trim();
    if (!value.startsWith('{') || !value.endsWith('}')) {
      throw FormatException('Invalid saved locale map: $savedLocale');
    }
    final body = value.substring(1, value.length - 1).trim();
    if (body.isEmpty) return <String, String>{};

    final result = <String, String>{};
    final entries = RegExp(
      r'(?:^|,\s*)([^,:{}]+):\s*(.*?)(?=,\s*[^,:{}]+:\s*|$)',
    ).allMatches(body);
    for (final entry in entries) {
      final key = entry.group(1)?.trim();
      final entryValue = entry.group(2)?.trim();
      if (key == null || key.isEmpty || entryValue == null) {
        throw FormatException('Invalid saved locale map: $savedLocale');
      }
      result[key] = entryValue;
    }
    if (result.isEmpty) {
      throw FormatException('Invalid saved locale map: $savedLocale');
    }
    return result;
  }

  Future<bool> hasCompletedSetup() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key);
  }
}
