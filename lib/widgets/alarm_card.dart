import 'dart:async';

import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/bus_following.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
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
    if (old.id != alarm.id) _saved = null;
    _reloadSaved();
  }

  Future<void> _reloadSaved() async {
    final saved = (await AlarmStorageService().loadAlarms())
        .where((alarm) => alarm.id == widget.alarm.id)
        .firstOrNull;
    if (mounted) setState(() => _saved = saved);
  }

  /// "Next bus": stops following the current bus and looks for the next.
  Future<void> _skipToNextBus() async {
    setState(() => _skipping = true);
    try {
      await AlarmLifecycleService(storage: AlarmStorageService(), server: AlarmServerService())
          .skipToNextBus(widget.alarm.id);
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
                if (widget.alarm.enabled &&
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
                color: widget.alarm.enabled
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
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: const LinearProgressIndicator(minHeight: 6),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (locked != null && canFollowOneBus(alarm))
              TextButton.icon(
                onPressed: _skipping ? null : _skipToNextBus,
                icon: const Icon(Icons.skip_next, size: 18),
                label: Text(AppStrings.text('alarm.next_bus')),
              ),
          ],
        ),
      ],
    );
  }
}
