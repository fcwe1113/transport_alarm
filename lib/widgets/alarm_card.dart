import 'dart:async';

import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/arrival_lock.dart';
import 'package:transport_alarm/services/bus_following.dart';
import 'package:transport_alarm/services/next_bus.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/widgets/arrival_progress_bar.dart';
import 'package:transport_alarm/widgets/route_pill_strip.dart';
import 'package:flutter/material.dart';

/// One alarm on the alarm list: its boarding window, stop, routes and
/// repeat, plus, while an occurrence is active, the bus it's following and a
/// "Next bus" button. In edit mode it shows delete and edit buttons in place
/// of the on/off switch.
class AlarmCard extends StatefulWidget {
  final TransportAlarm alarm;
  final ValueChanged<bool> onToggle;
  final bool isEditing;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  const AlarmCard({
    super.key,
    required this.alarm,
    required this.onToggle,
    this.isEditing = false,
    this.onDelete,
    this.onTap,
  });

  @override
  State<AlarmCard> createState() => _AlarmCardState();
}

class _AlarmCardState extends State<AlarmCard> with WidgetsBindingObserver {
  Timer? _refreshTimer;
  late Future<GtfsStop?> _stopFuture;
  // The alarm as last saved: the alarm checks, or on iOS the notification
  // extension, update the bus it's following without the list knowing.
  TransportAlarm? _saved;
  bool _skipping = false;
  // The buses "Previous bus" and "Next bus" would move to, looked up ahead
  // so the buttons can show their times, or stay off when there's none: for
  // which followed bus, and when they were last looked up.
  LockedArrival? _previousBus;
  LockedArrival? _nextBus;
  String? _neighboursFor;
  DateTime? _neighboursCheckedAt;
  bool _neighboursLoading = false;

  @override
  void initState() {
    super.initState();
    _stopFuture = _loadStop();
    _reloadSaved();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _reloadSaved());
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(AlarmCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The list rebuilds with fresh alarm objects after each change; only a
    // different alarm or stop needs reloading. List rows can also be reused
    // for another alarm after a delete.
    final old = oldWidget.alarm;
    final alarm = widget.alarm;
    if (old.gtfsStopId != alarm.gtfsStopId || old.localeCode != alarm.localeCode) {
      _stopFuture = _loadStop();
    }
    if (old.id != alarm.id) {
      _saved = null;
      _previousBus = null;
      _nextBus = null;
      _neighboursFor = null;
      _neighboursCheckedAt = null;
    }
    _reloadSaved();
  }

  Future<void> _reloadSaved() async {
    final saved = (await AlarmStorageService().loadAlarms())
        .where((alarm) => alarm.id == widget.alarm.id)
        .firstOrNull;
    if (!mounted) return;
    setState(() => _saved = saved);
    if (saved != null) unawaited(_refreshNeighbourBuses(saved));
  }

  /// Looks up the buses "Previous bus" and "Next bus" would move to, when
  /// the followed bus (or what's been skipped) changed, and otherwise at most
  /// once a minute.
  Future<void> _refreshNeighbourBuses(TransportAlarm alarm) async {
    final locked = alarm.lockedArrival;
    if (locked == null || !canFollowOneBus(alarm)) {
      _previousBus = null;
      _nextBus = null;
      _neighboursFor = null;
      return;
    }
    final key = '${locked.identity}|${locked.arrivalEpochSeconds}|${alarm.skippedArrivals.length}';
    final checkedAt = _neighboursCheckedAt;
    final recent = checkedAt != null && DateTime.now().difference(checkedAt) < const Duration(minutes: 1);
    if (_neighboursLoading || (key == _neighboursFor && recent)) return;
    if (key != _neighboursFor) {
      setState(() {
        _previousBus = null;
        _nextBus = null;
      });
    }
    _neighboursLoading = true;
    ({LockedArrival? previous, LockedArrival? next}) found = (previous: null, next: null);
    try {
      found = await findNeighbourBuses(alarm);
    } catch (e) {
      // Offline or the feed failed: no bus to move to until the next look.
      debugPrint('Could not look up the previous and next buses for ${alarm.id}: $e');
    } finally {
      _neighboursLoading = false;
    }
    _neighboursCheckedAt = DateTime.now();
    if (mounted) {
      setState(() {
        _previousBus = found.previous;
        _nextBus = found.next;
        _neighboursFor = key;
      });
    }
  }

  /// "Next bus": stops following the current bus and looks for the next.
  Future<void> _skipToNextBus() => _changeBus(
    (lifecycle) => lifecycle.skipToNextBus(widget.alarm.id),
  );

  /// "Previous bus": goes back to [bus], an earlier one within the window.
  Future<void> _followPreviousBus(LockedArrival bus) => _changeBus(
    (lifecycle) => lifecycle.followBus(widget.alarm.id, bus),
  );

  Future<void> _changeBus(Future<void> Function(AlarmLifecycleService lifecycle) change) async {
    setState(() => _skipping = true);
    try {
      await change(AlarmLifecycleService(storage: AlarmStorageService(), server: AlarmServerService()));
    } finally {
      if (mounted) setState(() => _skipping = false);
      await _reloadSaved();
    }
  }

  /// Hides the "check this alarm" marker of a converted alarm.
  Future<void> _dismissReview() async {
    final saved = _saved ?? widget.alarm;
    await AlarmStorageService().updateAlarm(saved.copyWith(needsReview: false));
    await _reloadSaved();
  }

  Future<GtfsStop?> _loadStop() =>
      GtfsDatabase.forLocale(widget.alarm.localeCode).getGtfsStopById(widget.alarm.gtfsStopId);

  // Back in the app, such as after "Next bus" on the countdown notification
  // opened it: show what changed meanwhile straight away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reloadSaved();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, "0");
    final m = t.minute.toString().padLeft(2, "0");
    return "$h:$m";
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.isEditing)
                  _buildSideButton(
                    color: Theme.of(context).colorScheme.errorContainer,
                    onTap: widget.onDelete,
                    horizontalPadding: 16,
                    icon: Icon(Icons.remove_circle, color: Theme.of(context).colorScheme.error, size: 24),
                  ),
                Expanded(child: _buildHeader()),
                if (widget.isEditing)
                  _buildSideButton(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    onTap: widget.onTap,
                    horizontalPadding: 12,
                    icon: Icon(
                      Icons.chevron_right_rounded,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 28,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Switch(
                      value: widget.alarm.enabled,
                      onChanged: widget.onToggle,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Center(
                  child: RoutePillStrip(
                    gtfsStopId: widget.alarm.gtfsStopId,
                    routeNumberFilter: widget.alarm.routeNumbers,
                    locale: widget.alarm.localeCode,
                  ),
                ),
                const SizedBox(height: 6),
                Text(widget.alarm.repeat.toInfoString() ?? ""),
                if ((_saved ?? widget.alarm).needsReview) ...[
                  const SizedBox(height: 6),
                  _buildReviewMarker(),
                ],
                if (_isSpent) ...[
                  const SizedBox(height: 4),
                  _buildSpentStatus(_saved ?? widget.alarm),
                ] else if (widget.alarm.enabled &&
                    widget.alarm.activeOccurrenceAt(DateTime.now()) != null) ...[
                  const SizedBox(height: 4),
                  _buildBusStatus(_saved ?? widget.alarm),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A repeating alarm that's done for this occurrence, until its next one
  /// starts. Its switch stays on: turning it off would cancel the repeats.
  bool get _isSpent {
    final alarm = _saved ?? widget.alarm;
    return alarm.enabled && alarm.spent && alarm.repeat.frequency != RepeatFrequency.none;
  }

  /// That a spent alarm is done, and when its next occurrence's window starts.
  Widget _buildSpentStatus(TransportAlarm alarm) {
    final colour = Theme.of(context).colorScheme.onSurfaceVariant;
    final now = DateTime.now();
    final when = describeNextRepeat(
      alarm.nextOccurrenceAfter(now).boardFrom,
      now,
      shortDate: MaterialLocalizations.of(context).formatShortMonthDay,
    );
    return Row(
      children: [
        Icon(Icons.check_circle_outline, size: 18, color: colour),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            AppStrings.text('alarm_card.spent', {'when': when}),
            style: TextStyle(color: colour, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// The window times and stop name; tapping it edits the alarm in edit mode.
  Widget _buildHeader() {
    return InkWell(
      onTap: widget.isEditing ? widget.onTap : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "${_formatTime(widget.alarm.windowStart)} - ${_formatTime(widget.alarm.windowEnd)}",
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: widget.alarm.enabled && !_isSpent
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 2),
            FutureBuilder(
              future: _stopFuture,
              builder: (context, snapshot) {
                final name = snapshot.data?.displayNameFor(AppStrings.languageCode)
                    ?? AppStrings.text('alarm.loading_stops');
                return Text(
                  name,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// A full-height edit-mode button at the card's side.
  Widget _buildSideButton({
    required Color color,
    required VoidCallback? onTap,
    required double horizontalPadding,
    required Widget icon,
  }) {
    return Material(
      color: color,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Center(child: icon),
        ),
      ),
    );
  }

  /// Asks the user to check a converted alarm's boarding times.
  Widget _buildReviewMarker() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: scheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AppStrings.text('alarm_card.check_times'),
                style: TextStyle(color: scheme.onTertiaryContainer, fontSize: 13),
              ),
            ),
            IconButton(
              tooltip: AppStrings.text('alarm_card.check_times.dismiss'),
              icon: Icon(Icons.close, size: 18, color: scheme.onTertiaryContainer),
              onPressed: _dismissReview,
            ),
          ],
        ),
      ),
    );
  }

  /// The bus the active occurrence is following, live or from the
  /// timetable, with "Next bus" where the alarm's routes can follow one bus;
  /// or that it's still looking for one within the window.
  Widget _buildBusStatus(TransportAlarm alarm) {
    final locked = alarm.lockedArrival;
    final mode = AppStrings.transportModeValues(alarm.transportMode);
    final text = locked == null
        ? AppStrings.text('alarm_card.looking', {
            ...mode,
            'from': _formatTime(alarm.windowStart),
            'to': _formatTime(alarm.windowEnd),
          })
        : AppStrings.text(locked.isLive ? 'alarm_card.following.live' : 'alarm_card.following.timetable', {
            ...mode,
            'route': locked.routeNumber,
            'time': _formatTime(TimeOfDay.fromDateTime(locked.arrival)),
          });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (locked == null)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: const LinearProgressIndicator(minHeight: 6),
          )
        else
          ArrivalProgressBar(
            // As the Android countdown notification; iOS doesn't save the
            // countdown's start, so it runs from when the bus was chosen.
            start: DateTime.fromMillisecondsSinceEpoch(
              (alarm.androidProgressStartEpochSeconds ?? locked.lockedAtEpochSeconds) * 1000,
            ),
            arrival: locked.arrival,
            rings: [
              for (final state in alarm.thresholdStates)
                (
                  time: locked.arrival.subtract(Duration(minutes: state.minutesBeforeArrival)),
                  done: state.outcome != ThresholdOutcome.pending &&
                      state.outcome != ThresholdOutcome.ringing,
                ),
            ],
            transportMode: alarm.transportMode,
          ),
        const SizedBox(height: 4),
        Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (locked != null && canFollowOneBus(alarm)) _buildChangeBusButtons(),
      ],
    );
  }

  /// "Previous bus" and "Next bus", each with the time of the bus it moves
  /// to. Each is off while that's being looked up, and when there's no such
  /// bus within the window.
  Widget _buildChangeBusButtons() {
    final looked = _neighboursFor != null;
    String label(LockedArrival? bus, String key) => bus != null
        ? AppStrings.text('$key.at', {'time': _formatTime(TimeOfDay.fromDateTime(bus.arrival))})
        : AppStrings.text(looked ? '$key.none' : key);
    final previous = _previousBus;
    final next = _nextBus;
    return Row(
      children: [
        Expanded(
          child: TextButton.icon(
            onPressed: _skipping || previous == null ? null : () => _followPreviousBus(previous),
            icon: const Icon(Icons.skip_previous, size: 18),
            label: Text(label(previous, 'alarm.previous_bus'), overflow: TextOverflow.ellipsis),
          ),
        ),
        Expanded(
          child: TextButton.icon(
            onPressed: _skipping || next == null ? null : _skipToNextBus,
            icon: const Icon(Icons.skip_next, size: 18),
            label: Text(label(next, 'alarm.next_bus'), overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
  }
}

/// When a spent alarm next starts, from [now]: "today 07:30" or "tomorrow
/// 07:30", the weekday within the next week ("Tue 07:30"), or else
/// [shortDate]'s date ("12 Dec 07:30").
String describeNextRepeat(
  DateTime next,
  DateTime now, {
  required String Function(DateTime) shortDate,
}) {
  const weekdayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  final time = "${next.hour.toString().padLeft(2, "0")}:${next.minute.toString().padLeft(2, "0")}";
  // Calendar days apart, unaffected by clock changes.
  final days = DateTime.utc(next.year, next.month, next.day)
      .difference(DateTime.utc(now.year, now.month, now.day))
      .inDays;
  if (days <= 0) return AppStrings.text('alarm_card.spent.today', {'time': time});
  if (days == 1) return AppStrings.text('alarm_card.spent.tomorrow', {'time': time});
  if (days < 7) return '${AppStrings.text('repeat.day.${weekdayKeys[next.weekday - 1]}')} $time';
  return '${shortDate(next)} $time';
}
