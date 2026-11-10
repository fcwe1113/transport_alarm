import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/transit/transport_mode.dart';

/// A ring time on [ArrivalProgress], as a fraction of the bar.
class ProgressPoint {
  final double position;
  /// Already rang or was skipped this occurrence.
  final bool done;

  const ProgressPoint(this.position, {this.done = false});

  @override
  bool operator ==(Object other) =>
      other is ProgressPoint && other.position == position && other.done == done;

  @override
  int get hashCode => Object.hash(position, done);

  @override
  String toString() => 'ProgressPoint($position, done: $done)';
}

/// Where the vehicle and each ring time sit on the countdown bar, laid out
/// as the Android countdown notification does (LiveUpdateCountdownPlugin):
/// the bar runs from [start] to [arrival] in 1000 steps, the vehicle is at
/// [now], and only ring times strictly between start and arrival are shown,
/// at most one per step and never on either end.
class ArrivalProgress {
  static const _steps = 1000;

  final double progress;
  final List<ProgressPoint> points;

  const ArrivalProgress._(this.progress, this.points);

  factory ArrivalProgress.compute({
    required DateTime start,
    required DateTime arrival,
    required DateTime now,
    required List<({DateTime time, bool done})> rings,
  }) {
    final startMillis = start.millisecondsSinceEpoch;
    final arrivalMillis = arrival.millisecondsSinceEpoch;
    final journey = max(1, arrivalMillis - startMillis);
    int step(int millis) => ((millis - startMillis) * _steps / journey).round();

    final progress = step(now.millisecondsSinceEpoch).clamp(0, _steps);
    final seen = <int>{};
    final points = <ProgressPoint>[];
    for (final ring in rings) {
      final millis = ring.time.millisecondsSinceEpoch;
      if (millis <= startMillis || millis >= arrivalMillis) continue;
      final position = step(millis).clamp(1, _steps - 1);
      if (seen.add(position)) points.add(ProgressPoint(position / _steps, done: ring.done));
    }
    return ArrivalProgress._(progress / _steps, points);
  }
}

/// The alarm card's countdown bar: a clock at the start, ring times as dots,
/// and the vehicle moving towards its arrival. Redraws every few seconds, so
/// the vehicle moves between reloads of the saved alarm.
class ArrivalProgressBar extends StatefulWidget {
  final DateTime start;
  final DateTime arrival;
  final List<({DateTime time, bool done})> rings;
  final String transportMode;

  const ArrivalProgressBar({
    super.key,
    required this.start,
    required this.arrival,
    required this.rings,
    required this.transportMode,
  });

  @override
  State<ArrivalProgressBar> createState() => _ArrivalProgressBarState();
}

class _ArrivalProgressBarState extends State<ArrivalProgressBar> {
  static const _iconSize = 20.0;
  // Matches the notification's ring point colour.
  static const _ringColour = Color(0xFFFF9800);
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  IconData get _vehicleIcon => switch (widget.transportMode) {
    TransportMode.tram => Icons.tram,
    TransportMode.train => Icons.train,
    _ => Icons.directions_bus,
  };

  @override
  Widget build(BuildContext context) {
    final colours = Theme.of(context).colorScheme;
    final layout = ArrivalProgress.compute(
      start: widget.start,
      arrival: widget.arrival,
      now: DateTime.now(),
      rings: widget.rings,
    );
    return Row(
      children: [
        Icon(Icons.schedule, size: _iconSize, color: colours.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              // The vehicle's centre follows progress, kept on the bar.
              final vehicleLeft =
                  (layout.progress * width - _iconSize / 2).clamp(0.0, width - _iconSize);
              return SizedBox(
                height: _iconSize,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _BarPainter(
                          layout: layout,
                          filled: colours.primary,
                          track: colours.primary.withValues(alpha: 0.25),
                          ring: _ringColour,
                          doneRing: colours.outline,
                        ),
                      ),
                    ),
                    Positioned(
                      left: vehicleLeft,
                      top: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: colours.surfaceContainerHighest,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(_vehicleIcon, size: _iconSize, color: colours.primary),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  final ArrivalProgress layout;
  final Color filled;
  final Color track;
  final Color ring;
  final Color doneRing;

  const _BarPainter({
    required this.layout,
    required this.filled,
    required this.track,
    required this.ring,
    required this.doneRing,
  });

  static const _barHeight = 6.0;
  static const _pointRadius = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final centreY = size.height / 2;
    final bar = RRect.fromLTRBR(
      0,
      centreY - _barHeight / 2,
      size.width,
      centreY + _barHeight / 2,
      const Radius.circular(_barHeight / 2),
    );
    canvas.drawRRect(bar, Paint()..color = track);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, size.width * layout.progress, size.height));
    canvas.drawRRect(bar, Paint()..color = filled);
    canvas.restore();
    for (final point in layout.points) {
      canvas.drawCircle(
        Offset(point.position * size.width, centreY),
        _pointRadius,
        Paint()..color = point.done ? doneRing : ring,
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.layout.progress != layout.progress ||
      !listEquals(old.layout.points, layout.points) ||
      old.filled != filled ||
      old.track != track ||
      old.ring != ring ||
      old.doneRing != doneRing;
}
