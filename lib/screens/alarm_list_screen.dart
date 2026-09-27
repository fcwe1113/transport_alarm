import 'package:flutter/foundation.dart';
import 'package:transport_alarm/screens/add_alarm_screen.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/widgets/alarm_card.dart';
import 'package:transport_alarm/widgets/app_shell.dart';
import 'package:flutter/material.dart';

import '../models/bus_alarm.dart';
import '../services/alarm_server_service.dart';

// this will be the main screen the app first goes to on first boot
// basically the iphone alarm screen with much more information per alarm (as theyre more complex)

/// StatefulWidget wrapper for the alarm list screen
class AlarmListScreen extends StatefulWidget {
  const AlarmListScreen({super.key});

  @override
  State<AlarmListScreen> createState() => _AlarmListScreenState();
}

/// State object within the alarm list screen
class _AlarmListScreenState extends State<AlarmListScreen> {
  final _lifecycle = AlarmLifecycleService(storage: AlarmStorageService(), server: AlarmServerService());
  List<BusAlarm> _alarms = [];
  bool _isEditing = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAlarms();
  }

  Future<void> _loadAlarms() async {
    final alarmList = await AlarmStorageService().loadAlarms();
    setState(() {
      _alarms = alarmList;
      _isLoading = false;
    });
  }

  /// Event trigger for switching alarm enabled bool
  Future<void> _toggleAlarm(int index) async { // this will trigger on alarm toggle change, and make a copy of the alarm but with the correct toggle state
    final alarm = _alarms[index];
    final result = await _lifecycle.setEnabled(alarm.id, !alarm.enabled);
    if (!result.succeeded && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Could not update alarm: ${result.errorMessage}")));
    }
    await _loadAlarms();
  }

  Future<void> _deleteAlarm(String id) async {
    await _lifecycle.deleteAlarm(id);
    await _loadAlarms();
  }

  Future<void> _editAlarm(BusAlarm alarm, int index) async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => AddAlarmScreen(alarmToEdit: alarm,)));
    await _loadAlarms();
  }

  Future<void> _navigateToAddAlarm() async {
    await Navigator.pushNamed(context, "/add-alarm");
    await _loadAlarms();
  }

  /// Draws the screen
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(),),);
    }
    return AppShell(
        title: "Alarm List",
        actions: [ if (_isEditing) IconButton(
          onPressed: _navigateToAddAlarm,
          icon: const Icon(Icons.add)), TextButton(onPressed: () {
            setState(() {
              _isEditing = !_isEditing;
            });
          }, child: Text(
            _isEditing ? "Done" : "Edit",
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ))],
          body: _alarms.isEmpty ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text("Alarm List empty", style: TextStyle(color: Colors.grey.shade600, fontSize: 32),),
            const SizedBox(height: 12,),
            ElevatedButton.icon(onPressed: _navigateToAddAlarm, icon: Icon(Icons.add), label: const Text("Add Alarm"),)
          ],),) : ListView.builder(itemCount: _alarms.length, itemBuilder: (context, index) {
            final alarm = _alarms[index];
            return AlarmCard(
              alarm: alarm,
              isEditing: _isEditing,
              onToggle: (_) => _toggleAlarm(index),
              onDelete: () => _deleteAlarm(alarm.id),
              onTap: _isEditing ? () => _editAlarm(alarm, index) : null,
            );
          })
    );
  }
}