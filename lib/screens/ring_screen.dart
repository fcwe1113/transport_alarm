import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transport_alarm/app_navigator.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/android_alarm_coordinator.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';

/// Android: the full-screen alarm shown while a threshold rings, over the
/// lock screen. Opened by the ring notification's full-screen alert or a tap
/// on it; closes once the threshold stops ringing, however that happens.
class RingScreen extends StatefulWidget {
  final String alarmId;
  const RingScreen({super.key, required this.alarmId});

  static const _window = MethodChannel('com.fcwe1113.transport_alarm/ring_window');
  static String? _showing;

  /// Shows the ring screen for [alarmId], once, on top of whatever is open.
  /// Waits for the first frame when the alert launched the app.
  static void show(String alarmId) {
    if (_showing == alarmId) return;
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => show(alarmId));
      return;
    }
    _showing = alarmId;
    unawaited(_setOverLockScreen(true));
    navigator
        .push(MaterialPageRoute<void>(builder: (_) => RingScreen(alarmId: alarmId)))
        .whenComplete(() {
      _showing = null;
      unawaited(_setOverLockScreen(false));
    });
  }

  /// Lets the app show over the lock screen and turn the screen on, only
  /// while a ring is showing.
  static Future<void> _setOverLockScreen(bool enabled) async {
    try {
      await _window.invokeMethod<void>('setOverLockScreen', {'enabled': enabled});
    } on Exception catch (e) {
      debugPrint('Ring window flags not set: $e');
    }
  }

  @override
  State<RingScreen> createState() => _RingScreenState();
}

class _RingScreenState extends State<RingScreen> {
  TransportAlarm? _alarm;
  String? _body;
  Timer? _poll;
  bool _acknowledging = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // The notification's own button, or the window ending, can also stop the
    // ring; this screen follows the saved alarm.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  ThresholdState? _ringingThreshold(TransportAlarm? alarm) => alarm?.thresholdStates
      .where((state) => state.outcome == ThresholdOutcome.ringing)
      .firstOrNull;

  Future<void> _refresh() async {
    final alarm = (await AlarmStorageService().loadAlarms())
        .where((a) => a.id == widget.alarmId)
        .firstOrNull;
    if (!mounted) return;
    if (alarm == null || !alarm.enabled || _ringingThreshold(alarm) == null) {
      _close();
      return;
    }
    final body = _body ?? await AndroidAlarmCoordinator(AlarmStorageService()).ringBody(alarm);
    if (!mounted) return;
    setState(() {
      _alarm = alarm;
      _body = body;
    });
  }

  Future<void> _acknowledge() async {
    setState(() => _acknowledging = true);
    await AndroidAlarmCoordinator(AlarmStorageService()).acknowledge(widget.alarmId);
    _close();
  }

  void _close() {
    _poll?.cancel();
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final alarm = _alarm;
    final threshold = _ringingThreshold(alarm);
    final theme = Theme.of(context);
    final scheme = ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark);
    return Theme(
      data: theme.copyWith(colorScheme: scheme),
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: alarm == null
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      const Spacer(),
                      Icon(Icons.alarm, size: 96, color: scheme.primary),
                      const SizedBox(height: 24),
                      Text(
                        AppStrings.text(
                          'notification.transport_arriving_soon',
                          AppStrings.transportModeValues(alarm.transportMode),
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(color: scheme.onSurface),
                      ),
                      if (threshold != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          AppStrings.text('ring.threshold', {'minutes': threshold.minutesBeforeArrival}),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(color: scheme.primary),
                        ),
                      ],
                      if (_body != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _body!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      const Spacer(),
                      SizedBox(
                        width: double.infinity,
                        height: 64,
                        child: FilledButton(
                          onPressed: _acknowledging ? null : _acknowledge,
                          child: Text(
                            AppStrings.text('notification.acknowledge_action'),
                            style: const TextStyle(fontSize: 20),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
