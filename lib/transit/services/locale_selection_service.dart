import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app language, the enabled transit regions, and setup progress, in
/// preferences. Region pickers edit an in-memory draft of the enabled
/// regions, which is only saved when confirmed.
///
/// Enabled regions map a locale code to its own setting: empty for Hong
/// Kong, and the comma-separated ATCO area codes for Great Britain.
class LocaleSelectionService {
  static const _key = "enabled_locales";
  static const _appLanguageKey = "app_language_code";
  static const _setupCompletedKey = "setup_completed";
  // The selection before a locale change, kept until its download succeeds.
  static const _pendingChangeKey = "locale_change_previous";
  static Map<String, String>? _localeSelectionDraft;
  static final ValueNotifier<Map<String, String>> _draftNotifier =
      ValueNotifier<Map<String, String>>(<String, String>{});

  static ValueListenable<Map<String, String>>
      get localeSelectionDraftListenable => _draftNotifier;

  /// The saved app language, or English (saved as the choice) when none is.
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

  /// One saved entry, a JSON object of locale code to setting.
  Map<String, String> _decodeLocale(String savedLocale) {
    final decoded = jsonDecode(savedLocale);
    if (decoded is Map<String, dynamic> &&
        decoded.values.every((value) => value is String)) {
      return decoded.cast<String, String>();
    }
    throw FormatException('Invalid saved locale map: $savedLocale');
  }

  /// Records [previous] as the selection to go back to if the locale change
  /// starting now doesn't finish, even if the app is killed partway.
  Future<void> markLocaleChangePending(Map<String, String> previous) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingChangeKey, jsonEncode(previous));
  }

  /// Called once a locale change has succeeded, or been undone.
  Future<void> clearPendingLocaleChange() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingChangeKey);
  }

  /// Puts back the selection from before a locale change that never
  /// finished, such as when the app was killed during its download, so the
  /// enabled regions match the installed data. Call at launch, before
  /// anything reads the enabled regions.
  Future<void> rollBackUnfinishedLocaleChange() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_pendingChangeKey);
    if (saved == null) return;
    try {
      await setEnabledLocales(_decodeLocale(saved));
    } on FormatException {
      // Nothing usable to go back to; keep the current selection.
    }
    await prefs.remove(_pendingChangeKey);
  }

  /// Installs from before the setup_completed flag existed count as set up
  /// once they have saved locales.
  Future<bool> hasCompletedSetup() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_setupCompletedKey) ?? prefs.containsKey(_key);
  }

  /// Set to false when the first data build starts and true once it has
  /// succeeded, so a failed or interrupted first build sends the user back
  /// through setup.
  Future<void> setSetupCompleted(bool completed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_setupCompletedKey, completed);
  }
}
