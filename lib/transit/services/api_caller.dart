import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class BatchCallItem<K, T> {
  final K key;
  final String endpointName;
  final String url;
  final T Function(String rawJson) parseRaw;

  const BatchCallItem({
    required this.key,
    required this.endpointName,
    required this.url,
    required this.parseRaw,
  });
}

class BatchCallResult<K, T> {
  final Map<K, T> results;
  final List<K> failedKeys;

  const BatchCallResult({required this.results, required this.failedKeys});
}

class ApiCaller {
  static const _defaultMaxAge = Duration(days: 7);

  Future<bool> _isStale(String providerCode, String endpointName, Duration maxAge) async {
    final prefs = await SharedPreferences.getInstance();
    final lastMillis = prefs.getInt("${providerCode}_${endpointName}_last_fetched");
    if (lastMillis == null) return true;
    final last = DateTime.fromMillisecondsSinceEpoch(lastMillis);
    return DateTime.now().difference(last) > maxAge;
  }

  Future<void> _markFetched(String providerCode, String endpointName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt("${providerCode}_${endpointName}_last_fetched", DateTime.now().millisecondsSinceEpoch);
  }

  Future<T?> call<T>({
    required String providerCode,
    required String endpointName,
    required String url,
    required T Function(String rawJson) parseRaw,
    bool forceRefresh = false,
    Duration maxAge = _defaultMaxAge
  }) async {
    final stale = forceRefresh || await _isStale(providerCode, endpointName, maxAge);
    if (!stale) return null;

    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception("$endpointName fetch failed: ${response.statusCode}");
    }

    final data = parseRaw(response.body);
    await _markFetched(providerCode, endpointName);
    return data;
  }

  Future<BatchCallResult<K, T>> callBatch<K, T>({ // possible bug here in api reattempt code (from ios test run)
    required String providerCode,
    required List<BatchCallItem<K, T>> items,
    int batchSize = 20,
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 5),
    bool forceRefresh = false,
    Duration maxAge = _defaultMaxAge,
    void Function(int done, int total)? onProgress
  }) async {
    final results = <K, T>{};
    var pending = List<BatchCallItem<K, T>>.from(items);
    var doneCount = 0;

    for (var attempt = 1; attempt <= maxAttempts && pending.isNotEmpty; attempt++) {
      if (attempt > 1) {
        onProgress?.call(doneCount, items.length);
        await Future.delayed(retryDelay);
      }

      final failed = <BatchCallItem<K, T>>[];

      for (var i = 0; i < pending.length; i += batchSize) {
        final batch = pending.skip(i).take(batchSize).toList();

        final batchResults = await Future.wait(batch.map((item) async {
          try {
            final value = await call<T>(
              providerCode: providerCode,
              endpointName: item.endpointName,
              url: item.url,
              parseRaw: item.parseRaw,
              forceRefresh: forceRefresh,
              maxAge: maxAge
            );
              return (item: item, value: value, failed: false);
            } catch (e) {
              return (item: item, value: null, failed: true);
            }
          })
        );

        for (final r in batchResults) {
          if (r.failed) {
            failed.add(r.item);
          } else {
            results[r.item.key] = r.value as T;
            doneCount++;
          }
        }
        onProgress?.call(doneCount, items.length);
      }
      pending = failed;
    }
    return BatchCallResult(results: results, failedKeys: pending.map((i) => i.key).toList());
  }

  Future<bool> isEndpointStale(String providerCode, String endpointName, {Duration maxAge = _defaultMaxAge}){
    return _isStale(providerCode, endpointName, maxAge);
  }
}