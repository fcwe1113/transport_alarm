import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// One request in [ApiCaller.callBatch], identified by [key] in the result.
class BatchCallItem<K, T> {
  final K key;
  final String endpointName;
  final String url;
  final T Function(String rawJson) parseRaw;
  final bool forceRefresh;

  const BatchCallItem({
    required this.key,
    required this.endpointName,
    required this.url,
    required this.parseRaw,
    this.forceRefresh = false,
  });
}

/// What [ApiCaller.callBatch] fetched, and the keys that still failed after
/// every attempt. Items skipped as fresh are in neither.
class BatchCallResult<K, T> {
  final Map<K, T> results;
  final List<K> failedKeys;

  const BatchCallResult({required this.results, required this.failedKeys});
}

/// HTTP calls for provider data, with a per-endpoint fetch time kept in
/// preferences, so endpoints fetched recently are skipped on refresh.
class ApiCaller {
  static const _defaultMaxAge = Duration(days: 7);
  static const requestTimeout = Duration(seconds: 20);

  static String _fetchedKey(String providerCode, String endpointName) =>
      "${providerCode}_${endpointName}_last_fetched";

  /// A one-off GET, timing out after [requestTimeout].
  static Future<http.Response> get(Uri uri) =>
      _request((client) => client.get(uri));

  static Future<http.Response> head(Uri uri) =>
      _request((client) => client.head(uri));

  static Future<http.Response> _request(
    Future<http.Response> Function(http.Client client) send,
  ) async {
    final client = http.Client();
    try {
      return await send(client).timeout(requestTimeout);
    } finally {
      client.close();
    }
  }

  Future<bool> _isStale(
    String providerCode,
    String endpointName,
    Duration maxAge,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final lastMillis = prefs.getInt(_fetchedKey(providerCode, endpointName));
    if (lastMillis == null) return true;
    final last = DateTime.fromMillisecondsSinceEpoch(lastMillis);
    final age = DateTime.now().difference(last);
    return age.isNegative || age > maxAge;
  }

  Future<void> _markFetched(String providerCode, String endpointName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _fetchedKey(providerCode, endpointName),
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Fetches [url] and parses it, unless the endpoint was fetched within
  /// [maxAge] and [forceRefresh] is off; then it returns null, and the caller
  /// keeps the data it already has. Throws on a non-200 response.
  Future<T?> call<T>({
    required String providerCode,
    required String endpointName,
    required String url,
    required T Function(String rawJson) parseRaw,
    bool forceRefresh = false,
    Duration maxAge = _defaultMaxAge,
  }) async {
    final stale =
        forceRefresh || await _isStale(providerCode, endpointName, maxAge);
    if (!stale) return null;

    final response = await get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception("$endpointName fetch failed: ${response.statusCode}");
    }

    final data = parseRaw(response.body);
    await _markFetched(providerCode, endpointName);
    return data;
  }

  /// Runs [items] through [call], [batchSize] at a time, retrying failures
  /// up to [maxAttempts] times after [retryDelay].
  // todo possible bug here in api reattempt code (from ios test run)
  Future<BatchCallResult<K, T>> callBatch<K, T>({
    required String providerCode,
    required List<BatchCallItem<K, T>> items,
    int batchSize = 20,
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 5),
    bool forceRefresh = false,
    Duration maxAge = _defaultMaxAge,
    void Function(int done, int total)? onProgress,
  }) async {
    final results = <K, T>{};
    var pending = List<BatchCallItem<K, T>>.from(items);
    var doneCount = 0;

    for (
      var attempt = 1;
      attempt <= maxAttempts && pending.isNotEmpty;
      attempt++
    ) {
      if (attempt > 1) {
        onProgress?.call(doneCount, items.length);
        await Future.delayed(retryDelay);
      }

      final failed = <BatchCallItem<K, T>>[];

      for (var i = 0; i < pending.length; i += batchSize) {
        final batch = pending.skip(i).take(batchSize).toList();

        final batchResults = await Future.wait(
          batch.map((item) async {
            try {
              final value = await call<T>(
                providerCode: providerCode,
                endpointName: item.endpointName,
                url: item.url,
                parseRaw: item.parseRaw,
                forceRefresh: forceRefresh || item.forceRefresh,
                maxAge: maxAge,
              );
              return (item: item, value: value, failed: false);
            } catch (e) {
              return (item: item, value: null, failed: true);
            }
          }),
        );

        for (final r in batchResults) {
          if (r.failed) {
            failed.add(r.item);
          } else if (r.value == null) {
            // call() returns null when this endpoint is still fresh. It was
            // skipped successfully, so don't cast null to T or retry it.
            doneCount++;
          } else {
            results[r.item.key] = r.value as T;
            doneCount++;
          }
        }
        onProgress?.call(doneCount, items.length);
      }
      pending = failed;
    }
    return BatchCallResult(
      results: results,
      failedKeys: pending.map((i) => i.key).toList(),
    );
  }
}
