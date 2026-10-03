import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:xml/xml.dart';

/// The fields required to retrieve one BODS timetable dataset.
class BodsTimetableDataset {
  final String id;
  final Uri url;

  const BodsTimetableDataset(this.id, this.url);

  /// Accepts API rows with safe absolute HTTP(S) download URLs.
  static BodsTimetableDataset? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final rawUrl = json['url'];
    if (id == null || rawUrl is! String) {
      throw const FormatException('BODS dataset row is missing its id or URL.');
    }
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      throw const FormatException('BODS dataset row contains an invalid URL.');
    }
    return BodsTimetableDataset(id, uri);
  }
}

/// Converts area-filtered TransXChange XML datasets into the app's GTFS tables.
class UkTxcImporter {
  final GtfsDatabase database;
  final Set<String> selectedAtcoAreas;
  final Directory workDirectory;
  final ProgressCallback? onProgress;

  UkTxcImporter({
    required this.database,
    required this.selectedAtcoAreas,
    required this.workDirectory,
    this.onProgress,
  });

  /// Downloads and imports each matching published BODS timetable dataset.
  Future<void> importDatasets(List<BodsTimetableDataset> datasets) async {
    final client = http.Client();
    final stops = <String, List<dynamic>>{};
    final routes = <String, List<dynamic>>{};
    final calendars = <String, List<dynamic>>{};
    final trips = <List<dynamic>>[];
    final stopTimes = <List<dynamic>>[];
    try {
      for (var index = 0; index < datasets.length; index++) {
        final dataset = datasets[index];
        onProgress?.call(
          AppStrings.text('transit.gtfs_updating'),
          index / datasets.length,
        );
        final file = File(
          '${workDirectory.path}/dataset_${_safeId(dataset.id)}.tmp',
        );
        final request = http.Request('GET', dataset.url);
        final response = await client
            .send(request)
            .timeout(ApiCaller.requestTimeout);
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException(
            'BODS dataset download failed: HTTP ${response.statusCode}',
            uri: dataset.url,
          );
        }
        await response.stream
            .timeout(ApiCaller.requestTimeout)
            .pipe(file.openWrite());
        await _parseDownloadedFile(
          dataset.id,
          file,
          stops,
          routes,
          calendars,
          trips,
          stopTimes,
        );
        await file.delete();

        // Keep the staging database bounded while many operator files arrive.
        if (trips.length >= 500) {
          await _flush(stops, routes, calendars, trips, stopTimes);
        }
      }
    } finally {
      client.close();
    }
    await _flush(stops, routes, calendars, trips, stopTimes);
    await database.removeUnreferencedGtfsRows();
    await database.interpolateMissingArrivalTimes();
    await database.materializeUkOperatorData();
  }

  /// Parses either a standalone XML dataset or the XML files in a ZIP dataset.
  Future<void> _parseDownloadedFile(
    String datasetId,
    File file,
    Map<String, List<dynamic>> stops,
    Map<String, List<dynamic>> routes,
    Map<String, List<dynamic>> calendars,
    List<List<dynamic>> trips,
    List<List<dynamic>> stopTimes,
  ) async {
    final input = InputFileStream(file.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      var xmlIndex = 0;
      for (final entry in archive.files) {
        if (!entry.isFile || !entry.name.toLowerCase().endsWith('.xml')) {
          continue;
        }
        final documentId = '${datasetId}_${xmlIndex++}';
        final xmlFile = File(
          '${workDirectory.path}/txc_${_safeId(documentId)}.xml',
        );
        final output = OutputFileStream(xmlFile.path);
        entry.writeContent(output);
        await output.close();
        await _parseXml(
          documentId,
          await xmlFile.readAsString(),
          stops,
          routes,
          calendars,
          trips,
          stopTimes,
        );
        await xmlFile.delete();
      }
      if (xmlIndex == 0) {
        // The ZIP decoder returns an empty archive for a plain XML stream.
        await _parseXml(
          datasetId,
          await file.readAsString(),
          stops,
          routes,
          calendars,
          trips,
          stopTimes,
        );
      }
    } on ArchiveException {
      // BODS also serves a single XML document rather than a ZIP archive.
      await _parseXml(
        datasetId,
        await file.readAsString(),
        stops,
        routes,
        calendars,
        trips,
        stopTimes,
      );
    } finally {
      input.close();
    }
  }

  /// Converts the common TransXChange service, journey, and timing-link elements.
  Future<void> _parseXml(
    String datasetId,
    String source,
    Map<String, List<dynamic>> stops,
    Map<String, List<dynamic>> routes,
    Map<String, List<dynamic>> calendars,
    List<List<dynamic>> trips,
    List<List<dynamic>> stopTimes,
  ) async {
    datasetId = _safeId(datasetId);
    final document = XmlDocument.parse(source);
    final elements = document.descendants.whereType<XmlElement>().toList();
    Iterable<XmlElement> named(String name) =>
        elements.where((element) => element.name.local == name);
    String? value(XmlElement element, String name) {
      for (final child in element.descendants.whereType<XmlElement>()) {
        if (child.name.local == name) {
          final text = child.innerText.trim();
          if (text.isNotEmpty) return text;
        }
      }
      return null;
    }

    final stopDetails = <String, List<dynamic>>{};
    for (final stop in named('AnnotatedStopPointRef')) {
      final ref = value(stop, 'StopPointRef');
      if (ref == null || !_isSelected(ref)) continue;
      final name = value(stop, 'CommonName') ?? value(stop, 'Name') ?? ref;
      final lat = double.tryParse(value(stop, 'Latitude') ?? '');
      final lon = double.tryParse(value(stop, 'Longitude') ?? '');
      stopDetails[ref] = [ref, name, lat ?? 0, lon ?? 0, ref];
      stops[ref] = stopDetails[ref]!;
    }

    final sectionLinks = <String, List<_TimingLink>>{};
    for (final section in named('JourneyPatternSection')) {
      final sectionId = _identifier(section);
      if (sectionId == null) continue;
      sectionLinks[sectionId] = [
        for (final link in section.children.whereType<XmlElement>())
          if (link.name.local == 'JourneyPatternTimingLink')
            _TimingLink.fromElement(link, value),
      ];
    }

    final patterns = <String, _Pattern>{};
    for (final pattern in named('JourneyPattern')) {
      final patternId = _identifier(pattern);
      if (patternId == null) continue;
      final refs = [
        for (final child in pattern.descendants.whereType<XmlElement>())
          if (child.name.local == 'JourneyPatternSectionRef')
            child.innerText.trim(),
      ];
      patterns[patternId] = _Pattern(
        patternId,
        value(pattern, 'LineRef') ?? '',
        value(pattern, 'Direction') ?? '',
        value(pattern, 'DestinationDisplay') ?? '',
        [for (final ref in refs) ...?sectionLinks[ref]],
      );
    }

    final services = <String, _Service>{};
    for (final service in named('Service')) {
      final serviceId = _identifier(service);
      if (serviceId == null) continue;
      final lines = named('Line').where((line) {
        // The line belongs to this service when the closest Service ancestor matches.
        XmlElement? parent = line.parentElement;
        while (parent != null && parent.name.local != 'Service') {
          parent = parent.parentElement;
        }
        return identical(parent, service);
      });
      final line = lines.isEmpty ? null : lines.first;
      final lineName = line == null
          ? value(service, 'LineName') ?? serviceId
          : value(line, 'LineName') ?? serviceId;
      final startDate = _date(value(service, 'StartDate'));
      final endDate = _date(value(service, 'EndDate'));
      final days = _operatingDays(service);
      services[serviceId] = _Service(
        serviceId,
        lineName,
        startDate,
        endDate,
        days,
      );
    }

    final operatingPeriodStart = _date(
      value(document.rootElement, 'StartDate'),
    );
    final operatingPeriodEnd = _date(value(document.rootElement, 'EndDate'));
    for (final journey in named('VehicleJourney')) {
      final journeyCode =
          value(journey, 'VehicleJourneyCode') ??
          value(journey, 'VehicleJourneyRef') ??
          _identifier(journey);
      final serviceRef = value(journey, 'ServiceRef');
      final patternRef = value(journey, 'JourneyPatternRef');
      if (journeyCode == null || serviceRef == null || patternRef == null) {
        continue;
      }
      final service = services[serviceRef];
      final pattern = patterns[patternRef];
      if (service == null || pattern == null || pattern.links.isEmpty) continue;
      final departure = _seconds(value(journey, 'DepartureTime'));
      if (departure == null) continue;

      // A vehicle journey may override section run times for this departure.
      final runtimeOverrides = <String, int>{};
      final activityOverrides = <String, Map<String, String>>{};
      for (final link in journey.descendants.whereType<XmlElement>()) {
        if (link.name.local != 'VehicleJourneyTimingLink') continue;
        final reference = value(link, 'JourneyPatternTimingLinkRef');
        if (reference == null) continue;
        final runtime = _durationSeconds(value(link, 'RunTime'));
        if (runtime > 0) runtimeOverrides[reference] = runtime;
        final activities = <String, String>{};
        for (final end in ['From', 'To']) {
          for (final child in link.children.whereType<XmlElement>()) {
            if (child.name.local != end) continue;
            for (final activity in child.descendants.whereType<XmlElement>()) {
              if (activity.name.local == 'Activity') {
                activities[end.toLowerCase()] = activity.innerText
                    .trim()
                    .toLowerCase();
              }
            }
          }
        }
        if (activities.isNotEmpty) activityOverrides[reference] = activities;
      }

      final routeName = pattern.lineRef.isNotEmpty
          ? pattern.lineRef
          : service.lineName;
      final routeId = 'uk_${datasetId}_${_safeId(routeName)}';
      routes[routeId] = [routeId, service.lineName, pattern.destination];
      final serviceId = 'uk_${datasetId}_${_safeId(service.id)}';
      final tripId = 'uk_${datasetId}_${_safeId(journeyCode)}';
      final direction = pattern.direction.toLowerCase().contains('in')
          ? '1'
          : '0';
      trips.add([routeId, serviceId, tripId, direction, pattern.destination]);

      final startDate = service.startDate ?? operatingPeriodStart;
      final endDate = service.endDate ?? operatingPeriodEnd;
      final operatingDays = service.days.any((day) => day == 1)
          ? service.days
          : _operatingDays(journey);
      if (operatingDays.any((day) => day == 1) &&
          startDate != null &&
          endDate != null) {
        calendars[serviceId] = [
          serviceId,
          ...operatingDays,
          startDate,
          endDate,
        ];
      } else {
        continue;
      }

      var seconds = departure;
      var sequence = 0;
      final firstStop = pattern.links.first.fromStop;
      if (firstStop != null &&
          pattern.links.first.fromActivity != 'pass' &&
          stopDetails.containsKey(firstStop)) {
        stopTimes.add([
          tripId,
          _formatTime(seconds),
          _formatTime(seconds),
          firstStop,
          sequence++,
        ]);
      }
      for (final link in pattern.links) {
        if (link.fromStop == null || link.toStop == null) continue;
        seconds += runtimeOverrides[link.id] ?? link.runSeconds;
        final journeyActivities = activityOverrides[link.id] ?? const {};
        final toActivity = journeyActivities['to'] ?? link.toActivity;
        if (toActivity != 'pass' && stopDetails.containsKey(link.toStop)) {
          final arrival = seconds;
          seconds += link.waitSeconds;
          stopTimes.add([
            tripId,
            _formatTime(arrival),
            _formatTime(seconds),
            link.toStop!,
            sequence++,
          ]);
        } else {
          seconds += link.waitSeconds;
        }
      }
    }
    if (trips.length >= 500) {
      await _flush(stops, routes, calendars, trips, stopTimes);
    }
  }

  /// Writes buffered converted records through the shared GTFS database API.
  Future<void> _flush(
    Map<String, List<dynamic>> stops,
    Map<String, List<dynamic>> routes,
    Map<String, List<dynamic>> calendars,
    List<List<dynamic>> trips,
    List<List<dynamic>> stopTimes,
  ) async {
    if (stops.isNotEmpty) {
      await database.batchInsertStops(stops.values.toList());
      stops.clear();
    }
    if (routes.isNotEmpty) {
      await database.batchInsertRoutes(routes.values.toList());
      routes.clear();
    }
    if (calendars.isNotEmpty) {
      await database.batchInsertCalendar(calendars.values.toList());
      calendars.clear();
    }
    if (trips.isNotEmpty) {
      await database.batchInsertTrips(List.of(trips));
      trips.clear();
    }
    if (stopTimes.isNotEmpty) {
      await database.batchInsertStopTimes(List.of(stopTimes));
      stopTimes.clear();
    }
  }

  /// Checks a stop's ATCO authority prefix against the current selection.
  bool _isSelected(String stopCode) =>
      selectedAtcoAreas.any(stopCode.startsWith);

  /// Reads the common XML ID attribute without assuming a namespace prefix.
  static String? _identifier(XmlElement element) {
    for (final attribute in element.attributes) {
      if (attribute.name.local.toLowerCase() == 'id') {
        return attribute.value;
      }
    }
    return null;
  }

  /// Converts an ISO date to GTFS YYYYMMDD.
  static String? _date(String? value) {
    if (value == null || value.length < 10) return null;
    final parts = value.substring(0, 10).split('-');
    if (parts.length != 3) return null;
    return '${parts[0]}${parts[1]}${parts[2]}';
  }

  /// Parses a TransXChange clock time to elapsed seconds after midnight.
  static int? _seconds(String? time) {
    if (time == null) return null;
    final parts = time.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    final second = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
    if (hour == null || minute == null) return null;
    return hour * 3600 + minute * 60 + second;
  }

  /// Keeps GTFS service times above 24:00 for journeys crossing midnight.
  static String _formatTime(int seconds) {
    final hour = (seconds ~/ 3600).toString().padLeft(2, '0');
    final minute = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final second = (seconds % 60).toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  /// Converts common TransXChange ISO-8601 durations into seconds.
  static int _durationSeconds(String? duration) {
    if (duration == null) return 0;
    final match = RegExp(
      r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    ).firstMatch(duration);
    if (match == null) return 0;
    final days = int.tryParse(match.group(1) ?? '0') ?? 0;
    final hours = int.tryParse(match.group(2) ?? '0') ?? 0;
    final minutes = int.tryParse(match.group(3) ?? '0') ?? 0;
    final seconds = double.tryParse(match.group(4) ?? '0') ?? 0;
    return days * 86400 + hours * 3600 + minutes * 60 + seconds.round();
  }

  /// Makes external dataset ids safe to use in local database and temporary ids.
  static String _safeId(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  /// Reads weekday flags from the service's regular operating profile.
  static List<int> _operatingDays(XmlElement service) {
    final profileNodes = service.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'DaysOfWeek',
    );
    final present = profileNodes
        .expand((node) => node.descendants.whereType<XmlElement>())
        .map((element) => element.name.local.toLowerCase())
        .toSet();
    final weekdays =
        present.contains('mondaytofriday') ||
        present.contains('mondaytosaturday') ||
        present.contains('mondaytosunday');
    final weekend = present.contains('weekend');
    return [
      (weekdays ||
              weekend ||
              present.contains('monday') ||
              present.contains('mondaytosunday'))
          ? 1
          : 0,
      (weekdays ||
              weekend ||
              present.contains('tuesday') ||
              present.contains('mondaytosunday'))
          ? 1
          : 0,
      (weekdays ||
              weekend ||
              present.contains('wednesday') ||
              present.contains('mondaytosunday'))
          ? 1
          : 0,
      (weekdays ||
              weekend ||
              present.contains('thursday') ||
              present.contains('mondaytosunday'))
          ? 1
          : 0,
      (weekdays ||
              weekend ||
              present.contains('friday') ||
              present.contains('mondaytosunday'))
          ? 1
          : 0,
      (weekend ||
              present.contains('mondaytosaturday') ||
              present.contains('saturday') ||
              present.contains('mondaytosunday'))
          ? 1
          : 0,
      (weekend ||
              present.contains('sunday') ||
              present.contains('mondaytosunday'))
          ? 1
          : 0,
    ];
  }
}

/// A TransXChange journey pattern with its resolved timing links.
class _Pattern {
  final String id;
  final String lineRef;
  final String direction;
  final String destination;
  final List<_TimingLink> links;

  const _Pattern(
    this.id,
    this.lineRef,
    this.direction,
    this.destination,
    this.links,
  );
}

/// Calendar range and weekly service mask from a TransXChange Service element.
class _Service {
  final String id;
  final String lineName;
  final String? startDate;
  final String? endDate;
  final List<int> days;

  const _Service(
    this.id,
    this.lineName,
    this.startDate,
    this.endDate,
    this.days,
  );
}

/// Stop-to-stop schedule interval extracted from a journey pattern section.
class _TimingLink {
  final String? id;
  final String? fromStop;
  final String? toStop;
  final String? fromActivity;
  final String? toActivity;
  final int runSeconds;
  final int waitSeconds;

  const _TimingLink(
    this.id,
    this.fromStop,
    this.toStop,
    this.fromActivity,
    this.toActivity,
    this.runSeconds,
    this.waitSeconds,
  );

  /// Resolves endpoint references and timing durations from an XML timing link.
  factory _TimingLink.fromElement(
    XmlElement element,
    String? Function(XmlElement, String) value,
  ) {
    String? endpoint(String container, String childName) {
      for (final child in element.children.whereType<XmlElement>()) {
        if (child.name.local != container) continue;
        for (final nested in child.descendants.whereType<XmlElement>()) {
          if (nested.name.local == childName) {
            return nested.innerText.trim();
          }
        }
      }
      return null;
    }

    return _TimingLink(
      UkTxcImporter._identifier(element),
      endpoint('From', 'StopPointRef'),
      endpoint('To', 'StopPointRef'),
      endpoint('From', 'Activity')?.toLowerCase(),
      endpoint('To', 'Activity')?.toLowerCase(),
      UkTxcImporter._durationSeconds(value(element, 'RunTime')),
      UkTxcImporter._durationSeconds(value(element, 'WaitTime')),
    );
  }
}
