import 'package:shared_preferences/shared_preferences.dart';

/// Records when each provider's data in each locale was last refreshed, and
/// decides whether it's due for another refresh. Providers call
/// [markRefreshed] after a refresh that fully succeeded, and ask [isStale]
/// instead of keeping their own timestamps.
///
/// Whether the stored data is actually present and usable is still each
/// provider's own check; this only tracks time and what was refreshed.
class StalenessTracker {
  static const defaultMaxAge = Duration(days: 7);

  /// Provider code for a locale's GTFS timetable feed.
  static const gtfsProviderCode = 'gtfs';

  /// [signature] describes what was refreshed when that depends on user
  /// choices, such as GB's selected areas. Changing the choice then makes the
  /// data stale without the provider tracking it separately.
  Future<void> markRefreshed(
    String locale,
    String providerCode, {
    String? signature,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _refreshedAtKey(locale, providerCode),
      DateTime.now().millisecondsSinceEpoch,
    );
    final signatureKey = _signatureKey(locale, providerCode);
    if (signature == null) {
      await prefs.remove(signatureKey);
    } else {
      await prefs.setString(signatureKey, signature);
    }
  }

  /// True if there's no record of a refresh, it's older than [maxAge], or it
  /// was for a different [signature].
  Future<bool> isStale(
    String locale,
    String providerCode, {
    Duration maxAge = defaultMaxAge,
    String? signature,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_signatureKey(locale, providerCode)) != signature) {
      return true;
    }
    final refreshedAt = await lastRefreshed(locale, providerCode);
    if (refreshedAt == null) return true;
    final age = DateTime.now().difference(refreshedAt);
    return age.isNegative || age > maxAge;
  }

  Future<DateTime?> lastRefreshed(String locale, String providerCode) async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(_refreshedAtKey(locale, providerCode));
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  String _refreshedAtKey(String locale, String providerCode) =>
      'staleness_${locale}_${providerCode}_refreshed_at';

  String _signatureKey(String locale, String providerCode) =>
      'staleness_${locale}_${providerCode}_signature';
}
