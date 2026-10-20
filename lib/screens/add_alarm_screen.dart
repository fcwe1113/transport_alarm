import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/models/alarm_route_config.dart';
import 'package:transport_alarm/screens/map_screen.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/notification_service.dart';
import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/widgets/app_shell.dart';
import 'package:transport_alarm/widgets/route_pill_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

import '../locale_registry.dart';
import '../services/alarm_lifecycle_service.dart';

class AddAlarmScreen extends StatefulWidget {
  final TransportAlarm? alarmToEdit;

  const AddAlarmScreen({super.key, this.alarmToEdit});

  @override
  State<AddAlarmScreen> createState() => _AddAlarmScreenState();
}

class _AddAlarmScreenState extends State<AddAlarmScreen> {
  final _formKey = GlobalKey<FormState>();

  TimeOfDay _leftTime = TimeOfDay.now();
  // 15 minutes after the start, wrapping past midnight.
  late TimeOfDay _rightTime = _fromMinutes(_toMinutes(_leftTime) + 15);
  int _sliderMinutes = 15;

  bool _isLoadingStops = true;
  List<GtfsStop> _loadedStops = [];
  GtfsStop? _selectedStop;
  TextEditingController? _searchController;

  Set<TransportRoute> _selectedRoutes = {};
  Set<TransportRoute> _availableRoutes = {};
  String? _lastDisplayedLanguageCode;

  RepeatPattern _repeatPattern = RepeatPattern.none;
  final Set<int> _selectedWeekdays = {1, 2, 3, 4, 5}; // 1 = mon ... 7 = sun
  late TextEditingController _monthlyDayController;
  late TextEditingController _thresholdController;
  late TextEditingController _attemptsController;
  late TextEditingController _messageController;

  bool _liveOnly = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _monthlyDayController = TextEditingController(text: DateTime.now().day.toString());
    _thresholdController = TextEditingController();
    _messageController = TextEditingController(text: AppStrings.text('alarm.wake_up_default'));
    _attemptsController = TextEditingController(text: "10");
    if (widget.alarmToEdit != null) {
      _prefillExistingAlarmData(widget.alarmToEdit!);
    } else {
      _loadBusStops();
    }
  }

  Future<void> _prefillExistingAlarmData(TransportAlarm alarm) async {
    _thresholdController.text = alarm.thresholdStates.map((t) => t.minutesBeforeArrival.toString()).join(",");
    _attemptsController.text = alarm.maxRingsPerThreshold.toString();
    _messageController.text = alarm.message;

    _leftTime = alarm.windowStart;
    _rightTime = alarm.windowEnd;
    _repeatPattern = alarm.repeat;
    _liveOnly = alarm.liveOnly;
    _sliderMinutes = _calculateDurationInMinutes(_leftTime, _rightTime);
    if (_sliderMinutes > 60) _sliderMinutes = 60;
    await _loadBusStops();
    final db = GtfsDatabase.forLocale(alarm.localeCode);
    final stop = await db.getGtfsStopById(alarm.gtfsStopId);
    if (stop != null) {
      final routes = await _routesServing(stop);
      String? destinationOf(Map<String, String> names) => names[AppStrings.languageCode] ?? names["en"];
      // Each saved route matches by its own destination, so routes with
      // different destinations all come back selected.
      final selectedRoutes = routes.where((r) {
        final saved = alarm.routeNumbers[r.routeNumber];
        return saved != null && destinationOf(saved) == destinationOf(r.destinationText);
      }).toSet();

      if (!mounted) return;
      setState(() {
        _selectedStop = stop;
        _availableRoutes = routes;
        _selectedRoutes = selectedRoutes;
        _searchController?.text = stop.displayNameFor(AppStrings.languageCode);
      });
    }
  }

  @override
  void dispose() {
    _monthlyDayController.dispose();
    _messageController.dispose();
    _attemptsController.dispose();
    _thresholdController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final languageCode = AppStrings.languageCode;
    if (_lastDisplayedLanguageCode == languageCode) return;
    _lastDisplayedLanguageCode = languageCode;
    final stop = _selectedStop;
    if (stop != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchController != null) {
          _searchController!.text = stop.displayNameFor(languageCode);
        }
      });
    }
  }

  /// The routes serving [stop], one per route number and destination in the
  /// app's language.
  Future<Set<TransportRoute>> _routesServing(GtfsStop stop) async =>
      TransportRoute.dedupeByRouteAndDestination(
        await GtfsDatabase.forLocale(stop.locale).getRoutesForGtfsStop(stop.id),
        languageCode: AppStrings.languageCode,
      ).toSet();

  Future<void> _loadBusStops() async {
    final stopsList = <GtfsStop>[];
    for (final locale in (await LocaleSelectionService().getEnabledLocales()).keys) {
      stopsList.addAll(await GtfsDatabase.forLocale(locale).getAllGtfsStops());
    }
    if (!mounted) return;
    setState(() {
      _loadedStops = stopsList;
      _isLoadingStops = false;
    });
  }

  void _onLeftTimeChanged(TimeOfDay newLeft) {
    final diff = _calculateDurationInMinutes(_leftTime, _rightTime);
    setState(() {
      _rightTime = _fromMinutes(_toMinutes(newLeft) + diff);
      _leftTime = newLeft;
    });
  }

  void _onRightTimeChanged(TimeOfDay newRight) {
    final diff = _calculateDurationInMinutes(_leftTime, newRight);
    _onSliderChanged((diff > 60 ? 60 : diff).toDouble());
    setState(() {
      _rightTime = newRight;
    });
  }

  void _onSliderChanged(double newMinutes) {
    setState(() {
      _sliderMinutes = newMinutes.round();
      _rightTime = _fromMinutes(_toMinutes(_leftTime) + _sliderMinutes);
    });
  }

  Future<void> _openMapPicker() async {
    final picked = await Navigator.push<GtfsStop>(context, MaterialPageRoute(builder: (context) => const MapScreen(pickerMode: true,)));
    if (picked == null) return; // user did not select stop
    final routeList = await _routesServing(picked);
    if (!mounted) return;
    setState(() {
      _selectedStop = picked;
      _availableRoutes = routeList;
      _selectedRoutes = {};
      _searchController?.text = _selectedStop!.displayNameFor(AppStrings.languageCode);
    });
  }

  Future<void> _compileAndSave() async {
    if (_isSaving) return;

    // Field errors show under their fields; the rest are collected here and
    // shown together in one dialog.
    final formValid = _formKey.currentState?.validate() ?? false;
    final errors = <String>[];
    if (_selectedStop == null) {
      errors.add(AppStrings.text('alarm.validation.no_stop'));
    } else if (_selectedRoutes.isEmpty) {
      errors.add(AppStrings.text('alarm.validation.no_routes'));
    }

    final days = _monthlyDayController.text;
    // Empty items such as "1,,2" or a trailing comma are skipped here; the
    // monthly check below reports them.
    final splitDays = days.split(",").map((d) => int.tryParse(d.trim())).whereType<int>().toSet();
    if (_repeatPattern.frequency == RepeatFrequency.weekly) {
      if (_selectedWeekdays.isEmpty) {
        errors.add(AppStrings.text('alarm.validation.no_weekdays'));
      }
    } else if (_repeatPattern.frequency == RepeatFrequency.monthly) {
      if (days.trim().isEmpty) {
        errors.add(AppStrings.text('alarm.validation.no_month_days'));
      } else {
        final invalidDays = days.split(",").any((d) {
          final parsed = int.tryParse(d.trim());
          return parsed == null || parsed < 1 || parsed > 31;
        });
        if (invalidDays) {
          errors.add(AppStrings.text('alarm.validation.invalid_month_days'));
        }
      }
    }

    if (!formValid || errors.isNotEmpty) {
      if (errors.isNotEmpty) {
        showDialog(context: context, builder: (context) => AlertDialog(
          title: Text(AppStrings.text('alarm.error.title')),
          content: Text(errors.join("\n")),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.text('common.ok')))],
        ));
      }
      return;
    }

    // Ask before any alarm data is committed. If the user declines, keep the
    // form open so they can grant access and try saving again.
    if (Platform.isAndroid) {
      setState(() => _isSaving = true);
      if (!await _requestAndroidAlarmPermissions()) {
        if (mounted) setState(() => _isSaving = false);
        return;
      }
    }

    // conversions, if user picked all weekdays convert to daily, etc

    if (_repeatPattern.frequency == RepeatFrequency.weekly) {
      if (_selectedWeekdays.containsAll({1, 2, 3, 4, 5, 6, 7})) _repeatPattern = RepeatPattern(frequency: RepeatFrequency.daily);
    } else if (_repeatPattern.frequency == RepeatFrequency.monthly) {
      if (splitDays.length == 31 && splitDays.first == 1 && splitDays.last == 31) _repeatPattern = RepeatPattern(frequency: RepeatFrequency.daily);
    }

    // warnings, allow user to return but can proceed if desired

    if (_calculateDurationInMinutes(_leftTime, _rightTime) > 60) {
      final proceed = await _showWarning(AppStrings.text('alarm.warning.long_window'));
      if (proceed != true) return;
    }

    if (_repeatPattern.frequency == RepeatFrequency.monthly && (splitDays.contains(29) || splitDays.contains(30) || splitDays.contains(31))) {
      final proceed = await _showWarning(AppStrings.text('alarm.warning.month_days'));
      if (proceed != true) return;
    }

    final alarmThresholds = _thresholdController.text.split(",").map((t) => int.tryParse(t.trim())).whereType<int>().map(
            (m) => ThresholdState(minutesBeforeArrival: m)
    ).toList()
      ..sort((a, b) => b.minutesBeforeArrival.compareTo(a.minutesBeforeArrival));

    // Resolve each selected route's operator stop now and persist its exact ETA
    // URL with the alarm, avoiding this GTFS mapping query during every push.
    final gtfsDatabase = GtfsDatabase.forLocale(_selectedStop!.locale);
    final routeApiConfigs = <AlarmRouteConfig>[]; // todo fill in gb api call
    for (final route in _selectedRoutes) {
      // GTFS-only locales' live APIs use the GTFS stop ID directly.
      final String? operatorStopId = LocaleRegistry.getLocale(_selectedStop!.locale).gtfsOnly
          ? _selectedStop!.id
          : await gtfsDatabase.getOperatorStopIdForRouteAtGtfsStop(
              operatorRouteId: route.id,
              gtfsStopId: _selectedStop!.id,
            );
      if (operatorStopId == null) continue;
      final config = _buildAlarmRouteConfig(route, operatorStopId);
      if (config != null) routeApiConfigs.add(config);
    }
    if (routeApiConfigs.length != _selectedRoutes.length) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(AppStrings.text('alarm.route_api.title')),
          content: Text(AppStrings.text('alarm.route_api.body')),
        ),
      );
      return;
    }

    // Route number to its destination names, in every language the data has.
    final routeInput = {
      for (final route in _selectedRoutes) route.routeNumber: route.destinationText,
    };

    final newAlarm = TransportAlarm(
        id: widget.alarmToEdit?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        gtfsStopId: _selectedStop!.id,
        routeApiConfigs: routeApiConfigs,
        routeNumbers: routeInput,
        windowStart: _leftTime,
        windowEnd: _rightTime,
        thresholdStates: alarmThresholds,
        maxRingsPerThreshold: int.tryParse(_attemptsController.text) ?? 10,
        repeat: RepeatPattern(
            frequency: _repeatPattern.frequency,
            weekdays: _repeatPattern.frequency == RepeatFrequency.weekly ? _selectedWeekdays.toList() : null,
            dayOfMonth: _repeatPattern.frequency == RepeatFrequency.monthly ? splitDays.toList() : null
        ),
        liveOnly: _liveOnly,
        message: _messageController.text,
        localeCode: _selectedStop!.locale,
        enabled: true,
    );

    final lifecycle = AlarmLifecycleService(storage: AlarmStorageService(), server: AlarmServerService());
    if (!Platform.isAndroid) setState(() => _isSaving = true);
    final result = await lifecycle.createAlarm(newAlarm);
    if (mounted) setState(() => _isSaving = false);
    if (!result.succeeded) {
      _showSnackBar(AppStrings.text('alarm.save_failed', {'error': result.errorMessage}));
      return;
    }
    if (Platform.isAndroid) await _askForBatteryExemption();
    if (mounted) Navigator.pop(context);
  }

  static const _batteryPromptDeclinedKey = 'battery_exemption_prompt_declined';

  /// Alarm checks run in the background, where Android's battery saving (and
  /// some phone makers' stricter versions of it) can delay or stop them. Asks
  /// once to be exempted; "Not now" isn't asked again.
  Future<void> _askForBatteryExemption() async {
    if (await Permission.ignoreBatteryOptimizations.isGranted) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_batteryPromptDeclinedKey) ?? false) return;
    if (!mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppStrings.text('alarm.battery.title')),
        content: Text(AppStrings.text('alarm.battery.body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.text('alarm.battery.not_now'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.text('alarm.battery.allow'))),
        ],
      ),
    );
    if (allow == true) {
      await Permission.ignoreBatteryOptimizations.request();
    } else {
      await prefs.setBool(_batteryPromptDeclinedKey, true);
    }
  }

  Future<bool> _requestAndroidAlarmPermissions() async {
    var notifications = await Permission.notification.status;
    if (!notifications.isGranted) {
      notifications = await Permission.notification.request();
    }
    if (!notifications.isGranted) {
      _showSnackBar(AppStrings.text('alarm.permission.notifications'));
      return false;
    }

    var exactAlarms = await Permission.scheduleExactAlarm.status;
    if (!exactAlarms.isGranted) {
      await Permission.scheduleExactAlarm.request();
      // Android may return from the settings screen before the permission
      // state is reflected in the request result, so check the current state.
      exactAlarms = await Permission.scheduleExactAlarm.status;
    }
    if (!exactAlarms.isGranted) {
      _showSnackBar(AppStrings.text('alarm.permission.exact'));
      return false;
    }

    final fullScreenAccess = await NotificationService.plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestFullScreenIntentPermission();
    if (fullScreenAccess != true) {
      _showSnackBar(AppStrings.text('alarm.permission.full_screen'));
      return false;
    }
    return true;
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  AlarmRouteConfig? _buildAlarmRouteConfig(TransportRoute route, String operatorStopId) {
    final provider = LocaleRegistry.getLocale(_selectedStop!.locale).transitProviders
        .where((candidate) => candidate.providerCode == route.providerCode)
        .firstOrNull;
    if (provider == null) return null;
    final apiUrl = provider.alarmEtaUrl(operatorStopId: operatorStopId, route: route);
    if (apiUrl == null) return null;

    return AlarmRouteConfig(
      routeNumber: route.routeNumber,
      mode: provider.transportMode,
      providerCode: route.providerCode,
      apiUrl: apiUrl,
    );
  }

  Future<bool?> _showWarning(String text) async {
    return showDialog(context: context, builder: (context) => AlertDialog(
      title: Text(AppStrings.text('alarm.warning.title')),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.text('common.go_back'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(AppStrings.text('common.continue')))
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(title: AppStrings.text(widget.alarmToEdit != null ? 'alarm.edit.title' : 'alarm.add.title'),
    selectedTab: 0,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: EdgeInsets.zero,
            ),
            child: const Icon(Icons.close),
          ),
          IconButton(
            onPressed: _isSaving ? null : _compileAndSave,
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            tooltip: AppStrings.text('alarm.save.tooltip'),
          ),
        ],
        body: Form(key: _formKey, child: ListView(padding: const EdgeInsets.all(16), children: [
          _buildTimeWindowCard(),
          const SizedBox(height: 12,),
          _buildStopSearch(),
          const SizedBox(height: 16,),
          if (_selectedStop != null) ...[
            _buildRouteList(),
            const SizedBox(height: 16,)
          ],
          _buildThresholdField(),
          const SizedBox(height: 24,),
          _buildRingAttemptsField(),
          const SizedBox(height: 24,),
          ..._buildRepeatSelector(),
          const SizedBox(height: 12,),

          // ignore schedule checkbox
          SwitchListTile(
            title: Text(AppStrings.text('alarm.ignore_scheduled')),
            subtitle: Text(AppStrings.text('alarm.live_only')),
            value: _liveOnly,
            onChanged: (bool val) {
              setState(() {
                _liveOnly = val;
              });
            }
          ),
          const SizedBox(height: 12,),
          _buildMessageField(),
        ],))
    );
  }

  /// The window's start and end times, the time between them, and a slider
  /// for the window's length.
  Widget _buildTimeWindowCard() {
    return Card(child: Padding(padding: const EdgeInsetsGeometry.all(16), child:
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(AppStrings.text('alarm.time_window'), style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12,),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [

          // left time button
          OutlinedButton.icon(onPressed: () async {
            final picked = await showTimePicker(context: context, initialTime: _leftTime);
            if (picked != null) _onLeftTimeChanged(picked);
          }, label: Text(_formatTime(_leftTime)), icon: const Icon(Icons.access_time),),

          // middle arrow / time diff
          Column(mainAxisSize: MainAxisSize.min, children: [Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
            child: Text(AppStrings.text('alarm.duration', {'minutes': _calculateDurationInMinutes(_leftTime, _rightTime)}), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),),
          ), const SizedBox(height: 2,), const Icon(Icons.arrow_forward, size: 20,)
          ],),

          // right time button
          OutlinedButton.icon(onPressed: () async {
            final picked = await showTimePicker(context: context, initialTime: _rightTime);
            if (picked != null) _onRightTimeChanged(picked);
          }, label: Text(_formatTime(_rightTime)), icon: const Icon(Icons.access_time))
        ],),
        const SizedBox(height: 12,),
        Row(children: [Text(AppStrings.text('alarm.slider.zero')), Expanded(child: Slider(
          value: _sliderMinutes + 0.0,
          onChanged: _onSliderChanged,
          min: 0,
          max: 60,
          divisions: 60,
          label: AppStrings.text('alarm.slider.minutes', {'minutes': _sliderMinutes}),
        )), Text(AppStrings.text('alarm.slider.maximum'))],)
      ],)
    ,),);
  }

  /// The stop search box, or a loading placeholder while stops load, with
  /// the button that picks a stop on the map instead.
  Widget _buildStopSearch() {
    return Row(children: [Expanded(child: _isLoadingStops ? TextFormField(
      enabled: false,
      decoration: InputDecoration(hintText: AppStrings.text('common.loading'), prefixIcon: const SizedBox(
        width: 20,
        height: 20,
        child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2,),),
      ), border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)))
    ) : Autocomplete<GtfsStop>(
      displayStringForOption: (GtfsStop option) => option.displayNameFor(AppStrings.languageCode),
      optionsBuilder: (TextEditingValue value) {
        if (value.text.isEmpty) return _loadedStops;
        final query = value.text.toLowerCase().trim();
        return _loadedStops.where((s) => s.displayNameFor(AppStrings.languageCode).toLowerCase().contains(query));
      },
      onSelected: (GtfsStop selection) async {
        FocusScope.of(context).unfocus();
        final routeList = await _routesServing(selection);
        if (!mounted) return;
        setState(() {
          _selectedStop = selection;
          _availableRoutes = routeList;
          _selectedRoutes = {};
        });
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        _searchController = controller;
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))
          ),
        );
      },
    )),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        onPressed: _openMapPicker,
        icon: const Icon(Icons.location_searching),
        tooltip: AppStrings.text('alarm.choose_map'),
      )],);
  }

  /// A checkbox for each route serving the selected stop.
  Widget _buildRouteList() {
    return Card(clipBehavior: Clip.antiAlias, child: ExpansionTile(
      initiallyExpanded: false,
      title: Text(
        AppStrings.text('alarm.routes_serving', {'stop': _selectedStop!.displayNameFor(AppStrings.languageCode)}),
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
      ),
      subtitle: Text(_selectedRoutes.isEmpty
          ? AppStrings.text('alarm.validation.no_routes')
          : AppStrings.text(
              _selectedRoutes.length == 1
                  ? 'alarm.routes_selected.one'
                  : 'alarm.routes_selected.other',
              {'count': _selectedRoutes.length},
            ),
      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),),
      children: _availableRoutes.map((r) {
        return CheckboxListTile(
          title: Row(
            children: [
              RoutePill(route: r),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.destinationNameFor(AppStrings.languageCode),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          value: _selectedRoutes.contains(r),
          onChanged: (bool? checked) {
            setState(() {
              if (checked == true) {
                _selectedRoutes.add(r);
              } else {
                _selectedRoutes.remove(r);
              }
            });
          },
        );
      }).toList(),
    ),);
  }

  /// How many minutes before arrival to ring, as a comma-separated list.
  Widget _buildThresholdField() {
    return Row(children: [
      Text(AppStrings.text('alarm.threshold_minutes_label'), style: const TextStyle(fontWeight: FontWeight.bold),),
      Expanded(child: TextFormField(controller: _thresholdController, decoration: InputDecoration(
          isDense: true, border: const UnderlineInputBorder(),
          hintText: AppStrings.text('alarm.threshold_hint')
      ),
        keyboardType: TextInputType.text,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r"[0-9,]"))],
        validator: (val) {
          if (val == null || val == "") {
            return AppStrings.text('alarm.validation.required');
          }

          final currentWindow = _calculateDurationInMinutes(_leftTime, _rightTime);
          for (final item in val.split(",")) {
            final minutes = int.tryParse(item);
            if (minutes == null) {
              return AppStrings.text('alarm.validation.comma');
            }
            if (minutes >= currentWindow) {
              return AppStrings.text('alarm.validation.window_exceeded');
            }
          }

          return null;
        },
      ))
    ],);
  }

  Widget _buildRingAttemptsField() {
    return Row(children: [
      Text(AppStrings.text('alarm.ring_attempts_label'), style: const TextStyle(fontWeight: FontWeight.bold),),
      Expanded(child: TextFormField(controller: _attemptsController, decoration: const InputDecoration(
          isDense: true,
          border: UnderlineInputBorder()
      ), keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        validator: (val) => val == null || val == "" ? AppStrings.text('alarm.validation.required') : int.parse(val) > 15 ? AppStrings.text('alarm.validation.max_rings') : null,
      ))
    ],);
  }

  /// The four-way repeat selector, plus the weekday chips or month-day field
  /// for weekly and monthly repeats.
  List<Widget> _buildRepeatSelector() {
    const weekdayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    return [
      Text(AppStrings.text('alarm.repeat_pattern'), style: const TextStyle(fontWeight: FontWeight.bold),),
      const SizedBox(height: 8,),
      SegmentedButton(segments: [
        ButtonSegment(value: RepeatPattern.none, label: Text(AppStrings.text('repeat.none'))),
        ButtonSegment(value: RepeatPattern(frequency: RepeatFrequency.daily), label: Text(AppStrings.text('repeat.daily'))),
        ButtonSegment(value: RepeatPattern(frequency: RepeatFrequency.weekly), label: Text(AppStrings.text('repeat.weekly'))),
        ButtonSegment(value: RepeatPattern(frequency: RepeatFrequency.monthly), label: Text(AppStrings.text('repeat.monthly'))),
      ], selected: {_repeatPattern}, onSelectionChanged: (Set<RepeatPattern> selected) {
        setState(() {
          _repeatPattern = selected.first;
        });
      },),

      if (_repeatPattern.frequency == RepeatFrequency.weekly) ...[
        const SizedBox(height: 12,),
        Wrap(
          spacing: 4,
          children: List.generate(7, (i) {
            final day = i + 1; // 1 = Monday, as DateTime.weekday
            return FilterChip(label: Text(AppStrings.text('repeat.day.short.${weekdayKeys[i]}')), selected: _selectedWeekdays.contains(day), onSelected: (bool selected) {
              setState(() {
                if (selected) {
                  _selectedWeekdays.add(day);
                } else {
                  _selectedWeekdays.remove(day);
                }
              });
            });
          }),
        )
      ],

      if (_repeatPattern.frequency == RepeatFrequency.monthly) ...[
        const SizedBox(height: 12,),
        Row(children: [
          Text(AppStrings.text('alarm.day_of_month'),),
          Expanded(child: TextField(
            controller: _monthlyDayController,
            keyboardType: TextInputType.text,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r"[0-9,]"))],
            decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: AppStrings.text('alarm.day_of_month_hint')),
          ))
        ],)
      ],
    ];
  }

  Widget _buildMessageField() {
    return Row(children: [
      Text(AppStrings.text('alarm.custom_message'), style: const TextStyle(fontWeight: FontWeight.bold),),
      Expanded(child: TextFormField(controller: _messageController, decoration: const InputDecoration(
          isDense: true,
          border: UnderlineInputBorder()
      ), validator: (val) => val == null || val == "" ? AppStrings.text('alarm.validation.required') : null,
      ))
    ],);
  }

  String _formatTime(TimeOfDay time) =>
      "${time.hour.toString().padLeft(2, "0")}:${time.minute.toString().padLeft(2, "0")}";

  int _toMinutes(TimeOfDay t) => t.hour * 60 + t.minute;
  TimeOfDay _fromMinutes(int m) => TimeOfDay(hour: (m ~/ 60) % 24, minute: m % 60);

  int _calculateDurationInMinutes(TimeOfDay start, TimeOfDay end) {
    int duration = _toMinutes(end) - _toMinutes(start);
    if (duration < 0) {
      duration += 24 * 60;
    }
    return duration;
  }

}
