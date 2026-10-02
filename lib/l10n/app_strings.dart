import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

/// Loads the shared JSON string catalog used by Flutter and native targets.
class AppStrings {
  static const _fallbackLocale = 'en';
  static Map<String, String> _catalog = const {};
  static String _languageCode = _fallbackLocale;

  static String get languageCode => _languageCode;

  static Future<void> load(String languageCode) async {
    Future<Map<String, String>> loadCatalog(String code) async {
      final json = await rootBundle.loadString(
        'assets/localization/strings_$code.json',
      );
      return (jsonDecode(json) as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, value as String),
      );
    }

    try {
      _catalog = await loadCatalog(languageCode);
      _languageCode = languageCode;
    } on FlutterError {
      _catalog = await loadCatalog(_fallbackLocale);
      _languageCode = _fallbackLocale;
    }
  }

  static String text(String key, [Map<String, Object?> values = const {}]) {
    var result = _catalog[key] ?? _fallbackCatalog[key] ?? key;
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
  };
}
