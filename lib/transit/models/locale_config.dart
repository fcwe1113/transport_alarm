class LocaleConfig {
  final String code;
  final String displayName;
  final Duration utcOffset;
  final String timeZoneIdentifier;

  const LocaleConfig({
    required this.code,
    required this.displayName,
    required this.utcOffset,
    required this.timeZoneIdentifier,
  });

  DateTime nowInLocale() => DateTime.now().toUtc().add(utcOffset);
}
