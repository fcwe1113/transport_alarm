import 'dart:convert';
import 'dart:io';

import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/models/bus_alarm.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';

class AlarmStorageService {
  Future<File> _file() async {
    return File("${(await AppGroupStorage.directory).path}/alarms.json");
  }

  Future<List<BusAlarm>> loadAlarms() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final rawJson = await file.readAsString();
    final List<dynamic> data = jsonDecode(rawJson);
    return data.map((a) => BusAlarm.fromJson(a as Map<String, dynamic>)).toList();
  }

  Future<void> saveAlarms(List<BusAlarm> alarms) async {
    final file = await _file();
    await file.create(recursive: true);
    final jsonList = alarms.map((a) => a.toJson()).toList();
    final temporaryFile = File('${file.path}.tmp');
    await temporaryFile.writeAsString(jsonEncode(jsonList), flush: true);
    await temporaryFile.rename(file.path);
  }

  Future<void> addAlarm(BusAlarm alarm) async {
    final alarms = await loadAlarms();
    alarms.add(alarm);
    await saveAlarms(alarms);
  }

  Future<void> updateAlarm(BusAlarm updated) async {
    final alarms = await loadAlarms();
    final index = alarms.indexWhere((a) => a.id == updated.id);
    if (index == -1) return; // todo check functionality
    alarms[index] = updated;
    await saveAlarms(alarms);
  }

  Future<void> updateLastEstimate(String alarmId, int estimate) async {
    final alarms = await loadAlarms();
    final index = alarms.indexWhere((alarm) => alarm.id == alarmId);
    if (index == -1) return;

    final alarm = alarms[index];
    final activeThreshold = alarm.thresholdStates
        .where((state) =>
            state.outcome == ThresholdOutcome.pending ||
            state.outcome == ThresholdOutcome.ringing)
        .firstOrNull;
    if (activeThreshold == null) return;
    final minutesUntilThreshold = estimate - activeThreshold.minutesBeforeArrival;
    if (alarm.lastEstimatedMinutesUntilThreshold == minutesUntilThreshold) return;

    alarms[index] = alarm.copyWith(
      lastEstimatedMinutesUntilThreshold: minutesUntilThreshold,
    );
    await saveAlarms(alarms);
  }

  Future<void> deleteAlarm(String id) async {
    final alarms = await loadAlarms();
    alarms.removeWhere((a) => a.id == id);
    await saveAlarms(alarms);
  }
}
