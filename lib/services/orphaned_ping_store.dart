import 'dart:convert';
import 'dart:io';

import 'package:transport_alarm/services/app_group_storage.dart';

/// Server pings the app failed to cancel, such as when offline, kept as
/// ping ID to secret in the App Group (orphaned_pings.json). The iOS
/// notification extension reads it to acknowledge such a ping the first
/// time it arrives, so the server stops sending it, and the app retries the
/// cancel on its next launch or resume.
class OrphanedPingStore {
  static const _fileName = 'orphaned_pings.json';

  static Future<File> get _file async => File('${(await AppGroupStorage.directory).path}/$_fileName');

  static Future<Map<String, String>> load() async {
    try {
      final file = await _file;
      if (!await file.exists()) return {};
      return (jsonDecode(await file.readAsString()) as Map<String, dynamic>).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  static Future<void> add(String pingId, String secret) async =>
      _save({...await load(), pingId: secret});

  static Future<void> remove(String pingId) async {
    final pings = await load();
    if (pings.remove(pingId) == null) return;
    await _save(pings);
  }

  static Future<void> _save(Map<String, String> pings) async {
    final file = await _file;
    // Written to a temporary file and renamed, so the extension never reads
    // half a file.
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(pings), flush: true);
    await temp.rename(file.path);
  }
}
