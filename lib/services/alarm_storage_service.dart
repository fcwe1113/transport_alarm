import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';

/// The saved alarms, in alarms.json in the App Group so the iOS
/// notification extension reads and updates the same list.
class AlarmStorageService {
  // Runs this isolate's read-modify-write operations one at a time, so two
  // updates can't read the same list and overwrite each other's changes.
  static Future<void> _queue = Future<void>.value();
  static final _random = Random();

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<File> _file() async {
    return File("${(await AppGroupStorage.directory).path}/alarms.json");
  }

  Future<List<TransportAlarm>> loadAlarms() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final rawJson = await file.readAsString();
    final List<dynamic> data = jsonDecode(rawJson);
    return data.map((a) => TransportAlarm.fromJson(a as Map<String, dynamic>)).toList();
  }

  Future<void> _save(List<TransportAlarm> alarms) async {
    final file = await _file();
    await file.create(recursive: true);
    final jsonList = alarms.map((a) => a.toJson()).toList();
    // A name of its own per write: the app and the background alarm isolate
    // can save at the same moment, and a shared temp file made one rename
    // fail.
    final temporaryFile = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}'
      '.${_random.nextInt(1 << 32)}.tmp',
    );
    try {
      await temporaryFile.writeAsString(jsonEncode(jsonList), flush: true);
      await temporaryFile.rename(file.path);
    } catch (_) {
      if (await temporaryFile.exists()) await temporaryFile.delete();
      rethrow;
    }
  }

  Future<void> addAlarm(TransportAlarm alarm) => _serialized(() async {
    final alarms = await loadAlarms();
    alarms.add(alarm);
    await _save(alarms);
  });

  /// Replaces the saved alarm with [updated]'s ID; does nothing if it's gone.
  Future<void> updateAlarm(TransportAlarm updated) =>
      _modify(updated.id, (_) => updated);

  /// Saves an arrival [estimate] (minutes from now) as the time left until
  /// the alarm's active threshold, which the iOS notification extension
  /// falls back on when a fetch fails.
  Future<void> updateLastEstimate(String alarmId, int estimate) =>
      _modify(alarmId, (alarm) {
        final activeThreshold = alarm.thresholdStates
            .where((state) =>
                state.outcome == ThresholdOutcome.pending ||
                state.outcome == ThresholdOutcome.ringing)
            .firstOrNull;
        if (activeThreshold == null) return null;
        final minutesUntilThreshold = estimate - activeThreshold.minutesBeforeArrival;
        if (alarm.lastEstimatedMinutesUntilThreshold == minutesUntilThreshold) return null;
        return alarm.copyWith(lastEstimatedMinutesUntilThreshold: minutesUntilThreshold);
      });

  /// Replaces the alarm [alarmId] with what [change] returns, or leaves the
  /// file untouched when the alarm is gone or [change] returns null.
  Future<void> _modify(String alarmId, TransportAlarm? Function(TransportAlarm alarm) change) =>
      _serialized(() async {
        final alarms = await loadAlarms();
        final index = alarms.indexWhere((alarm) => alarm.id == alarmId);
        if (index == -1) return;
        final changed = change(alarms[index]);
        if (changed == null) return;
        alarms[index] = changed;
        await _save(alarms);
      });

  Future<void> deleteAlarm(String id) => _serialized(() async {
    final alarms = await loadAlarms();
    alarms.removeWhere((a) => a.id == id);
    await _save(alarms);
  });
}
