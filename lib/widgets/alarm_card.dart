import 'dart:async';
import 'dart:io';

import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/transit/models/route_arrival.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/transit/services/arrival_resolver.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/widgets/route_pill_strip.dart';
import 'package:flutter/material.dart';

/// One alarm on the alarm list: its window, stop, routes and repeat, plus
/// the next arrival while the window is open. In edit mode it shows delete
/// and edit buttons in place of the on/off switch.
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

class _AlarmCardState extends State<AlarmCard> {
  Timer? _refreshTimer;
  // Bumped every minute, so the arrivals reload and the window is rechecked.
  int _refreshTick = 0;
  // Shown while the next load runs, so the estimate doesn't blank out.
  List<RouteArrival>? _lastArrivals;
  // Kept between builds, so a rebuild (such as the list entering edit mode)
  // doesn't query the database and the live APIs again. The arrivals start
  // on the first build inside the window, and again after each tick.
  late Future<GtfsStop?> _stopFuture;
  Future<List<RouteArrival>>? _arrivalsFuture;

  @override
  void initState() {
    super.initState();
    _stopFuture = _loadStop();
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      setState(() {
        _refreshTick++;
        _arrivalsFuture = null;
      });
    });
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
    if (old.id != alarm.id || old.gtfsStopId != alarm.gtfsStopId || (!old.enabled && alarm.enabled)) {
      _arrivalsFuture = null;
      _lastArrivals = null;
    }
  }

  Future<GtfsStop?> _loadStop() =>
      GtfsDatabase.forLocale(widget.alarm.localeCode).getGtfsStopById(widget.alarm.gtfsStopId);

  /// Loads the alarm's upcoming arrivals. On iOS, also saves the soonest
  /// usable one as the alarm's last estimate, for the notification extension.
  Future<List<RouteArrival>> _loadArrivalsAndPersistEstimate() async {
    final savedAlarm = (await AlarmStorageService().loadAlarms())
        .where((alarm) => alarm.id == widget.alarm.id)
        .firstOrNull;
    final alarm = savedAlarm ?? widget.alarm;
    final waitingForFirstEligibleBus =
        alarm.thresholdStates.isNotEmpty &&
        alarm.thresholdStates.every(
          (state) => state.outcome == ThresholdOutcome.pending,
        ) &&
        alarm.lastEstimatedMinutesUntilThreshold == null &&
        alarm.androidFallbackArrivalEpochSeconds == null;
    final arrivals = await resolveArrivals(
      gtfsStopId: alarm.gtfsStopId,
      routeNumberFilter: alarm.routeNumbers,
      minimumMinutesFromNow: waitingForFirstEligibleBus
          ? alarm.thresholdStates
                .map((state) => state.minutesBeforeArrival)
                .reduce((a, b) => a > b ? a : b)
          : null,
      locale: alarm.localeCode,
    );
    _lastArrivals = arrivals;
    if (Platform.isIOS) {
      final eligible = alarm.liveOnly
          ? arrivals.where((arrival) => arrival.isLive)
          : arrivals;
      if (eligible.isNotEmpty) {
        final estimate = eligible
            .reduce((a, b) => a.minutesFromNow <= b.minutesFromNow ? a : b)
            .minutesFromNow;
        await AlarmStorageService().updateLastEstimate(
          alarm.id,
          estimate,
        );
      }
    }
    return arrivals;
  }

  @override
  void dispose() {
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
                    icon: const Icon(Icons.remove_circle, color: Colors.red, size: 24),
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
                if (widget.alarm.enabled && widget.alarm.isWithinWindow(TimeOfDay.now())) ...[
                  const SizedBox(height: 4),
                  _buildNextArrival(),
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
                    : Colors.grey,
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
                    color: Colors.grey.shade600,
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

  /// The next arrival, reloaded every minute. While a reload runs it keeps
  /// showing the previous estimate, marked as updating.
  Widget _buildNextArrival() {
    return FutureBuilder<List<RouteArrival>>(
      key: ValueKey(_refreshTick),
      future: _arrivalsFuture ??= _loadArrivalsAndPersistEstimate(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          final previousArrivals = _lastArrivals;
          return _buildArrivalStatus(
            previousArrivals == null || previousArrivals.isEmpty
                ? AppStrings.text('alarm_card.loading_arrivals')
                : AppStrings.text('alarm_card.estimate_updating', {
                    'estimate': _formatNextArrival(previousArrivals),
                  }),
          );
        }

        final arrivals = snapshot.data;
        if (snapshot.hasError) {
          // todo implement seamless background load
          return _buildArrivalStatus(AppStrings.text('alarm_card.arrivals_failed'));
        }
        if (arrivals == null || arrivals.isEmpty) {
          return _buildArrivalStatus(AppStrings.text('alarm_card.no_arrivals'));
        }
        return _buildArrivalStatus(_formatNextArrival(arrivals));
      },
    );
  }

  Widget _buildArrivalStatus(String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          // todo attach progress bar to arrival
          child: const LinearProgressIndicator(minHeight: 6),
        ),
        const SizedBox(height: 4),
        Text(
          text,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  String _formatNextArrival(List<RouteArrival> arrivals) {
    final minutes = arrivals.first.minutesFromNow;
    return AppStrings.text(
      minutes == 1 ? 'alarm_card.next_arrival.one' : 'alarm_card.next_arrival.other',
      {'minutes': minutes},
    );
  }
}
