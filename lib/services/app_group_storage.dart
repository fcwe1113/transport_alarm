import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// File storage shared by the iOS app and its notification service extension.
class AppGroupStorage {
  static const _channel = MethodChannel(
    'com.fcwe1113.transport_alarm/app_group',
  );

  static Directory? _directory;

  /// The shared directory: the App Group container on iOS, the app's
  /// documents directory elsewhere. Looked up once per isolate; a failed
  /// lookup throws and is tried again on the next call.
  static Future<Directory> get directory async {
    final cached = _directory;
    if (cached != null) return cached;
    final Directory result;
    if (Platform.isIOS) {
      final path = await _channel.invokeMethod<String>('containerPath');
      if (path == null || path.isEmpty) {
        throw StateError('The iOS App Group container is unavailable.');
      }
      result = Directory(path);
    } else {
      result = await getApplicationDocumentsDirectory();
    }
    await result.create(recursive: true);
    return _directory = result;
  }

  static String? _deviceId;

  /// iOS: this phone's ID, which owns the server pings it schedules; null
  /// elsewhere or while iOS can't provide it. It changes when a backup is
  /// restored onto another phone, unlike the alarms file.
  static Future<String?> deviceId() async {
    if (!Platform.isIOS) return null;
    return _deviceId ??= await _channel.invokeMethod<String>('deviceId');
  }

  /// Mirrors the selected app language into the iOS App Group for extensions.
  static Future<void> setAppLanguageCode(String languageCode) async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod<void>(
      'setAppLanguageCode',
      {'languageCode': languageCode},
    );
  }
}
