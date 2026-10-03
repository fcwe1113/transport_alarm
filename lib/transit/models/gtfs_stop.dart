class GtfsStop {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final List<Map<String, String>> operatorNames;
  final String localeCode;

  const GtfsStop({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.operatorNames = const [],
    this.localeCode = 'hk',
  });

  String displayNameFor(String languageCode) => localizedNameFromOperators(
    operatorNames,
    languageCode,
    fallbackName: name,
  );

  static String localizedNameFromOperators(
    Iterable<Map<String, String>> names,
    String languageCode, {
    required String fallbackName,
  }) {
    final candidates =
        names
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

  static List<String> extractNameFragments(String rawName) {
    return rawName
        .split("|")
        .expand(
          (segment) => segment.split(RegExp(r"<BR>|/", caseSensitive: false)),
        )
        .map((f) => f.replaceAll(RegExp(r"^\[.*?\]\s*"), "").trim())
        .where((f) => f.isNotEmpty)
        .toSet()
        .toList();
  }

  static String cleanStopName(String rawName) {
    final fragments = extractNameFragments(rawName);

    if (fragments.isEmpty) return rawName;
    fragments.sort((a, b) => b.length.compareTo(a.length));
    return fragments.first;
  }

  static String normalizeForMatching(String name) {
    return name.toUpperCase().replaceAll(RegExp(r"[^A-Z0-9]"), "");
  }
}
