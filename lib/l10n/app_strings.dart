import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Loads the shared JSON string catalog used by Flutter and native targets.
class AppStrings {
  static const _fallbackLocale = 'en';
  static Map<String, String> _catalog = const {};
  // English, for any key the selected catalog is missing.
  static Map<String, String> _englishCatalog = const {};
  static String _languageCode = _fallbackLocale;

  static String get languageCode => _languageCode;

  /// Looks up the localized name for a transport mode. Add a
  /// `transport.mode.<mode>` entry to each locale catalog to add a mode.
  static String transportMode(String mode, {bool titleCase = false}) {
    final normalized = mode.trim().toLowerCase();
    final key = 'transport.mode.$normalized${titleCase ? '.title' : ''}';
    final localized = text(key);
    if (localized != key) return localized;
    if (normalized.isEmpty) return 'transport';
    return titleCase
        ? '${normalized[0].toUpperCase()}${normalized.substring(1)}'
        : normalized;
  }

  /// Supplies both grammatical forms used by localized UI templates.
  static Map<String, Object?> transportModeValues(String mode) => {
    'transportMode': transportMode(mode),
    'transportModeTitle': transportMode(mode, titleCase: true),
  };

  /// Loads [languageCode]'s catalog from assets/localization, or English
  /// when there's none for it, plus the English one to fall back on.
  static Future<void> load(String languageCode) async {
    Future<Map<String, String>> loadCatalog(String code) async {
      final json = await rootBundle.loadString(
        'assets/localization/strings_$code.json',
      );
      return (jsonDecode(json) as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, value as String),
      );
    }

    _englishCatalog = await loadCatalog(_fallbackLocale);
    if (languageCode == _fallbackLocale) {
      _catalog = _englishCatalog;
      _languageCode = _fallbackLocale;
      return;
    }
    try {
      _catalog = await loadCatalog(languageCode);
      _languageCode = languageCode;
    } on FlutterError {
      _catalog = _englishCatalog;
      _languageCode = _fallbackLocale;
    }
  }

  /// The string for [key] with each "{name}" replaced from [values]: from
  /// the selected catalog, then English, or the key itself when neither has it.
  static String text(String key, [Map<String, Object?> values = const {}]) {
    var result = _catalog[key] ?? _englishCatalog[key] ?? _fallbackCatalog[key] ?? key;
    for (final entry in values.entries) {
      result = result.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return result;
  }

  // Critical boot/background fallback strings; the JSON catalog remains the
  // canonical source and is loaded before any screen or notification runs.
  static const _fallbackCatalog = <String, String>{
    'notification.channel.rings': 'Alarm rings',
    'notification.channel.updates': 'Alarm updates',
    'notification.channel.rings.description':
        'Audible notifications for alarm thresholds.',
    'notification.channel.updates.description':
        'Silent arrival tracking and status updates.',
    'notification.channel.alerts': 'Alarm problems',
    'notification.channel.alerts.description':
        "Alerts when live arrival times can't be loaded or no bus is found.",
  };
}
