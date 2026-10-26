import 'package:flutter/widgets.dart';

/// Holds the selected interface language so settings can update MaterialApp live.
final ValueNotifier<String> appLanguageCodeNotifier = ValueNotifier('en');

/// The Flutter locale for an app language code; Chinese codes carry their
/// script ("zh-Hant", "zh-Hans").
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
