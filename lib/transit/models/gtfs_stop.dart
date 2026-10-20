import 'package:transport_alarm/locale_registry.dart';

/// A stop from a locale's GTFS timetable. HK stops also carry the names of
/// the operator stops matched to them, which are better and translated.
class GtfsStop {
  final String id;
  /// The GTFS stop_name, in the feed's language.
  final String name;
  final double lat;
  final double lng;
  /// Each matched operator stop's names, keyed by language code.
  final List<Map<String, String>> operatorNames;
  final String locale;

  const GtfsStop({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.operatorNames = const [],
    required this.locale,
  });

  /// The stop's name in [languageCode], falling back to English and then
  /// the GTFS name.
  String displayNameFor(String languageCode) {
    if (LocaleRegistry.getLocale(locale).gtfsOnly) {
      // No operator stops to take translated names from.
      return name;
    } else {
      return localizedNameFromOperators(
        operatorNames,
        languageCode,
        fallbackName: name,
      );
    }
  }

  /// The longest cleaned name among [names] in [languageCode] (or English),
  /// or [fallbackName] when there's none.
  static String localizedNameFromOperators(
    Iterable<Map<String, String>> names,
    String languageCode, {
    required String fallbackName,
  }) {
    final candidates = names
        .map((localizedNames) {
          final localized = localizedNames[languageCode]?.trim();
          if (localized != null && localized.isNotEmpty) return localized;
          return localizedNames['en']?.trim() ?? '';
        })
        .where((candidate) => candidate.isNotEmpty)
        .map(cleanStopName)
        .where((candidate) => candidate.isNotEmpty)
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return candidates.isEmpty ? fallbackName : candidates.first;
  }

  /// The distinct parts of an operator stop name, split on "|", "<BR>" and
  /// "/", without leading "[...]" tags.
  static List<String> extractNameFragments(String rawName) {
    return rawName
        .split("|")
        .expand((segment) => segment.split(RegExp(r"<BR>|/", caseSensitive: false)))
        .map((f) => f.replaceAll(RegExp(r"^\[.*?\]\s*"), "").trim())
        .where((f) => f.isNotEmpty)
        .toSet()
        .toList();
  }

  /// The longest fragment of [rawName], usually its most complete name.
  static String cleanStopName(String rawName) {
    final fragments = extractNameFragments(rawName);

    if (fragments.isEmpty) return rawName;
    fragments.sort((a, b) => b.length.compareTo(a.length));
    return fragments.first;
  }

  /// Upper-case letters and digits only, for matching operator stop names
  /// to GTFS ones. Only suits Latin-script names.
  static String normalizeForMatching(String name) {
    return name.toUpperCase().replaceAll(RegExp(r"[^A-Z0-9]"), "");
  }
}
