import 'package:flutter/widgets.dart';

/// Holds the selected interface language so settings can update MaterialApp live.
final ValueNotifier<String> appLanguageCodeNotifier = ValueNotifier('en');

/// Lets language changes replace the current route stack with a freshly built page.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

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
