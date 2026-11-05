import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';

/// Copies the app's data where the user can reach it, leaving the live files
/// where only the app (and on iOS its notification extension) can:
/// - iOS: the Documents folder, which file sharing shows in the Files app
///   and in Finder.
/// - Android: the app's external files folder
///   (`Android/data/<package>/files`), visible over USB on a computer.
class AppDataExport {
  /// The folder the export goes to, replaced on every export.
  static const folderName = 'Export';

  static Future<Directory> _exportRoot() async {
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external == null) throw StateError('No external storage is available.');
      return external;
    }
    return getApplicationDocumentsDirectory();
  }

  /// Alarm fields left out of the export: a ping secret authorises changes
  /// to that alarm's server pings, and the device ID says which phone owns
  /// them, so a shared export mustn't carry either.
  static const _privateAlarmFields = ['pingSecret', 'pingDeviceId'];

  /// Writes alarms.json and each enabled region's database to [folderName]
  /// in the platform's export location, and returns that folder.
  static Future<Directory> export() async {
    final folder = Directory('${(await _exportRoot()).path}/$folderName');
    if (await folder.exists()) await folder.delete(recursive: true);
    await folder.create(recursive: true);

    final alarms = File('${(await AppGroupStorage.directory).path}/alarms.json');
    if (await alarms.exists()) {
      final data = jsonDecode(await alarms.readAsString());
      if (data is List) {
        for (final alarm in data.whereType<Map<String, dynamic>>()) {
          for (final field in _privateAlarmFields) {
            alarm.remove(field);
          }
        }
      }
      await File('${folder.path}/alarms.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    }

    for (final locale in (await LocaleSelectionService().getEnabledLocales()).keys) {
      try {
        await GtfsDatabase.forLocale(locale).exportTo('${folder.path}/$locale.db');
      } on LocaleDataMissingException {
        // An enabled region whose data isn't downloaded yet has nothing to export.
      }
    }
    if (Platform.isAndroid) {
      // Files the app creates are readable by the app alone, but a computer
      // reads this folder over USB through the media service, which only
      // shares the folder's group. Letting the group read them makes them
      // reachable over USB (and through adb).
      await Process.run('chmod', ['-R', 'g+r', folder.path]);
    }
    return folder;
  }
}
