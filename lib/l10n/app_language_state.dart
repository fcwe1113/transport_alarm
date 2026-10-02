import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Holds the selected interface language so settings can update MaterialApp live.
final ValueNotifier<String> appLanguageCodeNotifier = ValueNotifier('en');

Locale localeForAppLanguage(String code) {
  switch (code) {
    case 'zh-Hant':
      return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
    case 'zh-Hans':
      return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans');
    default:
      return Locale(code);
  }
}
