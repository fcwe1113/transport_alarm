import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:transport_alarm/services/app_group_storage.dart';

/// Removes the scratch files a GTFS sync creates, including ones left behind
/// when the app was killed mid-sync. Never touches a live `<locale>.db`, or a
/// `.backup` left by an older version, which GtfsDatabase uses to recover an
/// interrupted install.
///
/// Only call this when no sync is running: after a sync finishes, or at app
/// startup before any sync can begin.
class TempFileCleaner {
  static Future<void> sweep() async {
    try {
      final appDir = await AppGroupStorage.directory;
      // Work folder for downloaded GB region archives.
      await _deleteMatching(appDir, (entity, name) =>
          entity is Directory && name.startsWith('gb_gtfs_'));
      // Extraction folders, one per GTFS archive (gtfs_<locale>_<random>).
      await _deleteMatching(appDir, (entity, name) =>
          entity is Directory &&
          !name.startsWith('gtfs_download_') &&
          RegExp(r'^gtfs_[A-Za-z]+_').hasMatch(name));
      // Downloaded HK archives.
      await _deleteMatching(appDir, (entity, name) =>
          entity is File &&
          name.startsWith('gtfs_download_') &&
          name.endsWith('.tmp'));
      // Staging databases and their journal, WAL and shared-memory files.
      await _deleteMatching(Directory(p.join(appDir.path, 'gtfs')),
          (entity, name) => entity is File && name.contains('.db.staging.'));
      // Disk-backed ID indexes used while filtering an import.
      await _deleteMatching(Directory.systemTemp, (entity, name) =>
          entity is Directory && name.startsWith('gtfs_id_index_'));
    } catch (e) {
      debugPrint('Temp file cleanup failed: $e');
    }
  }

  static Future<void> _deleteMatching(
    Directory dir,
    bool Function(FileSystemEntity entity, String name) matches,
  ) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (!matches(entity, p.basename(entity.path))) continue;
      try {
        await entity.delete(recursive: true);
      } catch (e) {
        // Keep going; one locked file shouldn't stop the rest.
        debugPrint('Could not delete ${entity.path}: $e');
      }
    }
  }
}
