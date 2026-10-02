// service to cache the api outputs
// transition to caching the dataclass themselves later

import 'dart:convert';
import 'dart:io';

import 'package:transport_alarm/services/app_group_storage.dart';

class CachedEntry<T> {
  final T data;
  final DateTime lastUpdated;
  final String sourceUrl;

  const CachedEntry({required this.data, required this.lastUpdated, required this.sourceUrl});

  bool isStale(Duration maxAge) => DateTime.now().difference(lastUpdated) > maxAge;
}

/// Persists and retrieves raw (unparsed) API response bodies for
/// each transit provider, keyed by [providerCode] and [endpoint].
class TransitCacheService {
  static const _schemaVersion = 1;

  Future<void> save<T>({
    required String providerCode,
    required String endpointName,
    required T data,
    required String sourceUrl,
    required Map<String, dynamic> Function(T) toJson,
  }) async {
    final file = await _fileFor(providerCode, endpointName);
    await file.create(recursive: true);
    final envelope = {
      "schemaVersion": _schemaVersion,
      "lastUpdated": DateTime.now().millisecondsSinceEpoch,
      "sourceUrl": sourceUrl,
      "data": toJson(data),
    };
    await file.writeAsString(jsonEncode(envelope));
  }

  Future<CachedEntry<T>?> load<T>({
    required String providerCode,
    required String endpointName,
    required T Function(Map<String, dynamic>) fromJson,
  }) async {
    final file = await _fileFor(providerCode, endpointName);
    if (!await file.exists()) return null;

    final envelope = jsonDecode(await file.readAsString());
    if (envelope["schemaVersion"] != _schemaVersion) return null;

    return CachedEntry(
      data: fromJson(envelope["data"]),
      lastUpdated: DateTime.fromMillisecondsSinceEpoch(envelope["lastUpdated"]),
      sourceUrl: envelope["sourceUrl"],
    );
  }

  Future<File> _fileFor(String providerCode, String endpoint) async { // the code that enforces file structure
    final dir = await AppGroupStorage.directory;
    return File("${dir.path}/transit_cache/$providerCode/$endpoint.json");
  }
}
