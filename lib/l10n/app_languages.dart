import 'package:transport_alarm/l10n/app_language_state.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';

/// Interface languages the app ships string catalogs for, named in their own
/// language so they can be picked before the app language is known.
const appLanguages = <({String code, String name})>[
  (code: 'en', name: "English"),
  (code: 'zh-Hant', name: "正體中文"),
  (code: 'zh-Hans', name: "简体中文"),
  (code: 'ja', name: "日本語"),
  (code: 'fr', name: "Français"),
  (code: 'es', name: "Español"),
  (code: 'de', name: "Deutsch"),
  (code: 'nl', name: "Nederlands"),
  (code: 'it', name: "Italiano"),
  (code: 'pl', name: "Polski"),
  (code: 'ko', name: "한국어"),
  (code: 'uk', name: "Українська"),
];

/// Saves [code] as the app language and loads its strings, so pages built
/// afterwards use it.
Future<void> applyAppLanguage(String code) async {
  await LocaleSelectionService().setAppLanguageCode(code);
  await AppStrings.load(code);
  await AppGroupStorage.setAppLanguageCode(code);
  appLanguageCodeNotifier.value = code;
}
