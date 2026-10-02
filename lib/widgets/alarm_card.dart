import 'dart:async';
import 'dart:io';

import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/transit/models/route_arrival.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/transit/services/arrival_resolver.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/widgets/route_pill_strip.dart';
import 'package:flutter/material.dart';

import '../transit/models/gtfs_stop.dart';

/// the per alarm display on the alarm list screen
/// basically the gui template for each given alarm
class AlarmCard extends StatefulWidget {
  // note it takes the alarm object as required input
  final TransportAlarm alarm;
  final ValueChanged<bool> onToggle; // callback for a value changing
  final bool _isEditing;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  const AlarmCard({
    super.key,
    required this.alarm,
    required this.onToggle,
    this._isEditing = false,
    this.onDelete,
    this.onTap,
  });

  @override
  State<AlarmCard> createState() => _AlarmCardState();
}

class _AlarmCardState extends State<AlarmCard> {
  Timer? _refreshTimer;
  int _refreshTick = 0;
  List<RouteArrival>? _lastArrivals;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      setState(() => _refreshTick++);
    });
  }

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

  bool get _withinActiveWindow {
    final now = TimeOfDay.now();
    final nowMin = now.hour * 60 + now.minute;
    final startMin =
        widget.alarm.windowStart.hour * 60 + widget.alarm.windowStart.minute;
    final endMin =
        widget.alarm.windowEnd.hour * 60 + widget.alarm.windowEnd.minute;

    if (startMin <= endMin) {
      return nowMin >= startMin && nowMin <= endMin;
    } else {
      // in case start and end cross midnight
      return nowMin >= startMin || nowMin <= endMin;
    }
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, "0");
    final m = t.minute.toString().padLeft(2, "0");
    return "${h}:${m}";
  }

  @override
  Widget build(BuildContext context) {
    final db = GtfsDatabase.forLocale("hk"); // todo fix locale hardcode
    final isActive = _withinActiveWindow;
    return Card(
      // groups up everything within visually
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
                if (widget._isEditing) ...[
                  Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: InkWell(
                      onTap: widget.onDelete,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Center(
                          child: Icon(
                            Icons.remove_circle,
                            color: Colors.red,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                Expanded(
                  child: InkWell(
                    onTap: widget._isEditing ? widget.onTap : null,
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
                            future: db.getGtfsStopById(widget.alarm.gtfsStopId),
                            builder: (context, snapshot) {
                              final rawName = snapshot.data?.name;
                              final name = rawName != null
                                  ? GtfsStop.cleanStopName(rawName)
                                  : AppStrings.text('alarm.loading_stops');
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
                  ),
                ),
                if (widget._isEditing)
                  Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: InkWell(
                      onTap: widget.onTap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Center(
                          child: Icon(
                            Icons.chevron_right_rounded,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            size: 28,
                          ),
                        ),
                      ),
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
            padding: EdgeInsets.all(12),
            child: Column(
              children: [
                const SizedBox(height: 6),
                RoutePillStrip(
                  gtfsStopId: widget.alarm.gtfsStopId,
                  routeNumberFilter: widget.alarm.routeNumbers,
                ),
                const SizedBox(height: 6),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(widget.alarm.repeat.toInfoString() ?? ""),
                      ],
                    ),
                  ],
                ),
                if (widget.alarm.enabled && isActive) ...[
                  const SizedBox(height: 4),
                  FutureBuilder<List<RouteArrival>>(
                    key: ValueKey(_refreshTick),
                    future: _loadArrivalsAndPersistEstimate(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        final previousArrivals = _lastArrivals;
                        final previousEstimate =
                            previousArrivals != null &&
                                previousArrivals.isNotEmpty
                            ? _formatNextArrival(previousArrivals)
                            : null;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                minHeight: 6,
                                value: null,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              previousEstimate == null
                                  ? AppStrings.text('alarm_card.loading_arrivals')
                                  : AppStrings.text('alarm_card.estimate_updating', {
                                      'estimate': previousEstimate,
                                    }),
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        );
                      }

                      final arrivals = snapshot.data;
                      final String contents;

                      if (snapshot.hasError) {
                        // todo implement seamless background load
                        contents = AppStrings.text('alarm_card.arrivals_failed');
                      } else if (arrivals == null || arrivals.isEmpty) {
                        contents = AppStrings.text('alarm_card.no_arrivals');
                      } else {
                        contents = _formatNextArrival(arrivals);
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              minHeight: 6,
                              value: null,
                            ), // todo attach progress bar to arrival
                          ),
                          const SizedBox(height: 4),
                          Text(
                            contents,
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
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
