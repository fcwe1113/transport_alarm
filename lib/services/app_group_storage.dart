import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// File storage shared by the iOS app and its notification service extension.
class AppGroupStorage {
  static const _channel = MethodChannel(
    'com.fcwe1113.transport_alarm/app_group',
  );

  static Future<Directory> get directory async {
    final Directory result;
    if (Platform.isIOS) {
      print("retrieving working dirs");
      final path = await _channel.invokeMethod<String>('containerPath');
      if (path == null || path.isEmpty) {
        throw StateError('The iOS App Group container is unavailable.');
      }
      result = Directory(path);
      print("retrieved working dirs: ${result.toString()}");
    } else {
      result = await getApplicationDocumentsDirectory();
    }
    await result.create(recursive: true);
    return result;
  }

  /// Copies existing app documents into the shared location during app launch.
  /// Existing shared files win so an extension update is never overwritten.
  static Future<void> migrateLegacyDocuments() async {
    if (!Platform.isIOS) return;

    final source = await getApplicationDocumentsDirectory();
    final destination = await directory;
    await _copyMissingContents(source, destination);
  }

  static Future<void> _copyMissingContents(
    Directory source,
    Directory destination,
  ) async {
    if (!await source.exists()) return;
    await destination.create(recursive: true);

    await for (final entity in source.list(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      final targetPath = '${destination.path}/$name';
      if (entity is Directory) {
        await _copyMissingContents(entity, Directory(targetPath));
      } else if (entity is File) {
        final target = File(targetPath);
        if (!await target.exists()) {
          await target.parent.create(recursive: true);
          await entity.copy(target.path);
        }
      }
    }
  }
}
