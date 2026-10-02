import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/models/alarm_route_config.dart';
import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/screens/map_screen.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/notification_service.dart';
import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/widgets/app_shell.dart';
import 'package:transport_alarm/widgets/route_pill_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

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
  TimeOfDay _rightTime = TimeOfDay.now().replacing(
      minute: (TimeOfDay.now().minute + 15) % 60,
      hour: TimeOfDay.now().hour + (TimeOfDay.now().minute + 15 >= 60 ? 1 : 0)
  );
  int _sliderMinutes = 15;

  bool _isLoadingStops = true;
  List<GtfsStop> _loadedStops = [];
  GtfsStop? _selectedStop;
  TextEditingController? _searchController;

  Set<TransportRoute> _selectedRoutes = {};
  Set<TransportRoute> _availableRoutes = {};

  RepeatPattern _repeatPattern = RepeatPattern.none;
  final Set<int> _selectedWeekdays = {1, 2, 3, 4, 5}; // 1 = mon ... 7 = sun
  late TextEditingController _monthlyDayController;
  late TextEditingController _thresholdController;
  late TextEditingController _attemptsController;
  late TextEditingController _messageController;

  bool _liveOnly = false;
  bool _isSaving = false;

  final alarmStorage = AlarmStorageService();

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
    _attemptsController.text = alarm.thresholdStates.first.ringCount.toString();
    _messageController.text = alarm.message;

    _leftTime = alarm.windowStart;
    _rightTime = alarm.windowEnd;
    _repeatPattern = alarm.repeat;
    _liveOnly = alarm.liveOnly;
    _sliderMinutes = _calculateDurationInMinutes(_leftTime, _rightTime);
    if (_sliderMinutes > 60) _sliderMinutes = 60;
    await _loadBusStops();
    final db = GtfsDatabase.forLocale("hk"); // todo remove locale hardcode
    final stop = await db.getGtfsStopById(alarm.gtfsStopId);
    if (stop != null) {
      final routes = TransportRoute.dedupeByRouteAndDestination(
        await db.getRoutesForGtfsStop(alarm.gtfsStopId),
      );
      final selectedRoutes = routes.where((r) => alarm.routeNumbers.contains(r.routeNumber)).toSet();

      setState(() {
        _selectedStop = stop;
        _availableRoutes = routes.toSet();
        _selectedRoutes = selectedRoutes;
        _searchController?.text = GtfsStop.cleanStopName(stop.name);
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

  Future<void> _loadBusStops() async {
    final stopsList = await GtfsDatabase.forLocale("hk").getAllGtfsStops();
    setState(() {
      _loadedStops = stopsList;
      _isLoadingStops = false;
    });
  }

  void _onLeftTimeChanged(TimeOfDay newLeft) {
    // if (newLeft.isAfter(_rightTime)) newLeft.subtract(Duration(days: 1));
    final diff = _calculateDurationInMinutes(_leftTime, _rightTime);
    setState(() {
      _rightTime = _fromMinutes(_toMinutes(newLeft) + diff);
      _leftTime = newLeft;
    });
  }

  void _onRightTimeChanged(TimeOfDay newRight) {
    // if (newRight.isBefore(_leftTime)) newRight = newRight.add(Duration(days: 1)); // add one day if newRight is "before" the left time
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

  void _openMapPicker() async {
    final picked = await Navigator.push<GtfsStop>(context, MaterialPageRoute(builder: (context) => const MapScreen(pickerMode: true,)));
    if (picked == null) return; // user did not select stop
    final routeList = Set<TransportRoute>.from(await GtfsDatabase.forLocale("hk").getRoutesForGtfsStop(picked.id)); // todo remove locale hardcode
    setState(() {
      _selectedStop = picked;
      _availableRoutes = routeList;
      _selectedRoutes = {};
      _searchController?.text = GtfsStop.cleanStopName(_selectedStop!.name);
    });
  }

  Future<void> _compileAndSave() async {
    if (_isSaving) return;

    // errors
    bool error = false;
    String errorMsg = "";
    if (!(_formKey.currentState?.validate() ?? false)) {
      error = true;
    }
    if (_selectedStop == null) {
      error = true;
      errorMsg += "${AppStrings.text('alarm.validation.no_stop')}\n";
    } else if (_selectedRoutes.isEmpty) {
      error = true;
      errorMsg += "${AppStrings.text('alarm.validation.no_routes')}\n";
    }

    final days = _monthlyDayController.text;
    final splitDays = days.split(",").map((d) => int.tryParse(d)!).whereType<int>().toSet();
    if (_repeatPattern.frequency == RepeatFrequency.weekly) {
      if (_selectedWeekdays.isEmpty) {
        error = true;
        errorMsg += "${AppStrings.text('alarm.validation.no_weekdays')}\n";
      }
    } else if (_repeatPattern.frequency == RepeatFrequency.monthly) {
      if (days.trim().isEmpty) {
        error = true;
        errorMsg += "${AppStrings.text('alarm.validation.no_month_days')}\n";
      } else {
        final invalidDays = days.split(",").any((d) {
          final parsed = int.tryParse(d.trim());
          return parsed == null || parsed < 1 || parsed > 31;
        });
        if (invalidDays) {
          error = true;
          errorMsg += "${AppStrings.text('alarm.validation.invalid_month_days')}\n";
        }
      }
    }

    if (error) {
      if (errorMsg != "") {
        showDialog(context: context, builder: (context) => AlertDialog(
          title: Text(AppStrings.text('alarm.error.title')),
          content: Text(errorMsg),
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
            (m) => ThresholdState(minutesBeforeArrival: m, ringCount: int.tryParse(_attemptsController.text) ?? 10)
    ).toList()
      ..sort((a, b) => b.minutesBeforeArrival.compareTo(a.minutesBeforeArrival));

    // Resolve each selected route's operator stop now and persist its exact ETA
    // URL with the alarm, avoiding this GTFS mapping query during every push.
    final gtfsDatabase = GtfsDatabase.forLocale("hk"); // todo remove locale hardcode
    final routeApiConfigs = <AlarmRouteConfig>[];
    for (final route in _selectedRoutes) {
      final operatorStopId = await gtfsDatabase.getOperatorStopIdForRouteAtGtfsStop(
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

    final newAlarm = TransportAlarm(
        id: widget.alarmToEdit?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        gtfsStopId: _selectedStop!.id,
        routeApiConfigs: routeApiConfigs,
        routeNumbers: _selectedRoutes.map((r) => r.routeNumber).toList(),
        windowStart: _leftTime,
        windowEnd: _rightTime,
        thresholdStates: alarmThresholds,
        repeat: RepeatPattern(
            frequency: _repeatPattern.frequency,
            weekdays: _repeatPattern.frequency == RepeatFrequency.weekly ? _selectedWeekdays.toList() : null,
            dayOfMonth: _repeatPattern.frequency == RepeatFrequency.monthly ? splitDays.toList() : null
        ),
        liveOnly: _liveOnly,
        message: _messageController.text,
        enabled: true,
    );

    final lifecycle = AlarmLifecycleService(storage: AlarmStorageService(), server: AlarmServerService());
    if (widget.alarmToEdit != null && !Platform.isAndroid) {
      await lifecycle.deleteAlarm(newAlarm.id); // iOS still replaces its server-scheduled ping.
    }
    if (!Platform.isAndroid) setState(() => _isSaving = true);
    final result = await lifecycle.createAlarm(newAlarm);
    if (mounted) setState(() => _isSaving = false);
    if (!result.succeeded) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.text('alarm.save_failed', {'error': result.errorMessage}))),
        );
      }
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<bool> _requestAndroidAlarmPermissions() async {
    var notifications = await Permission.notification.status;
    if (!notifications.isGranted) {
      notifications = await Permission.notification.request();
    }
    if (!notifications.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.text('alarm.permission.notifications')),
          ),
        );
      }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppStrings.text('alarm.permission.exact'),
            ),
          ),
        );
      }
      return false;
    }

    final fullScreenAccess = await NotificationService.plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestFullScreenIntentPermission();
    if (fullScreenAccess != true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppStrings.text('alarm.permission.full_screen'),
            ),
          ),
        );
      }
      return false;
    }
    return true;
  }

  AlarmRouteConfig? _buildAlarmRouteConfig(TransportRoute route, String operatorStopId) {
    final provider = availableProviders
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
          // time range selector slider
          Card(child: Padding(padding: const EdgeInsetsGeometry.all(16), child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(AppStrings.text('alarm.time_window'), style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12,),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [

                // left time button
                OutlinedButton.icon(onPressed: () async {
                  final picked = await showTimePicker(context: context, initialTime: _leftTime);
                  if (picked != null) _onLeftTimeChanged(picked);
                }, label: Text("${_leftTime.hour.toString().padLeft(2, "0")}:${_leftTime.minute.toString().padLeft(2, "0")}"), icon: const Icon(Icons.access_time),),

                // middle arrow / time diff
                Column(mainAxisSize: MainAxisSize.min, children: [Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
                  child: Text(AppStrings.text('alarm.duration', {'minutes': _calculateDurationInMinutes(_leftTime, _rightTime)}), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),),
                ), const SizedBox(height: 2,), const Icon(Icons.arrow_forward, size: 20,)
                ],),

                // right time button
                OutlinedButton.icon(onPressed: () async {
                  final picked = await showTimePicker(context: context, initialTime: _rightTime);
                  if (picked != null) _onRightTimeChanged(picked);
                }, label: Text("${_rightTime.hour.toString().padLeft(2, "0")}:${_rightTime.minute.toString().padLeft(2, "0")}"), icon: const Icon(Icons.access_time))
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
          ,),),

          const SizedBox(height: 12,),

          // bus stop search bar
          Row(children: [Expanded(child: _isLoadingStops ? TextFormField(
            enabled: false,
            decoration: InputDecoration(hintText: AppStrings.text('common.loading'), prefixIcon: const SizedBox(
              width: 20,
              height: 20,
              child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2,),),
            ), border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)))
          ) : Autocomplete<GtfsStop>(
            displayStringForOption: (GtfsStop option) => GtfsStop.cleanStopName(option.name),
            optionsBuilder: (TextEditingValue value) {
              if (value.text.isEmpty) return _loadedStops;
              final query = value.text.toLowerCase().trim();
              return _loadedStops.where((s) => GtfsStop.cleanStopName(s.name).toLowerCase().contains(query));
            },
            onSelected: (GtfsStop selection) async {
              FocusScope.of(context).unfocus();
              final routeList = TransportRoute.dedupeByRouteAndDestination(
                await GtfsDatabase.forLocale("hk").getRoutesForGtfsStop(selection.id),
              ).toSet();
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
                    hintText: AppStrings.text('alarm.stop_search'),
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
            )],),
          const SizedBox(height: 16,),

          // routes checkbox list
          if (_selectedStop != null) ...[
            Card(clipBehavior: Clip.antiAlias, child: ExpansionTile(
              initiallyExpanded: false,
              title: Text(
                AppStrings.text('alarm.routes_serving', {'stop': GtfsStop.cleanStopName(_selectedStop!.name)}),
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
                          r.destinationText["en"] ?? "",
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
            ),),
            const SizedBox(height: 16,)
          ],

          // how early to ring
          Row(children: [
            Text(AppStrings.text('alarm.threshold_minutes_label'), style: const TextStyle(fontWeight: FontWeight.bold),),
            Expanded(child: TextFormField(controller: _thresholdController, decoration: InputDecoration(
                isDense: true, border: UnderlineInputBorder(),
                hintText: AppStrings.text('alarm.threshold_hint')
            ),
              keyboardType: TextInputType.text,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r"[0-9,]"))],
              validator: (val) {
                if (val == null || val == "") {
                  return AppStrings.text('alarm.validation.required');
                }

                final currentWindow = _calculateDurationInMinutes(_leftTime, _rightTime);
                final items = val.split(",");

                for (final item in items) {
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
          ],),
          const SizedBox(height: 24,),

          // max ring attempts
          Row(children: [
            Text(AppStrings.text('alarm.ring_attempts_label'), style: const TextStyle(fontWeight: FontWeight.bold),),
            Expanded(child: TextFormField(controller: _attemptsController, decoration: const InputDecoration(
                isDense: true,
                border: UnderlineInputBorder()
            ), keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (val) => val == null || val == "" ? AppStrings.text('alarm.validation.required') : int.parse(val) > 15 ? AppStrings.text('alarm.validation.max_rings') : null,
            ))
          ],),
          const SizedBox(height: 24,),

          // horizontal 4 way repeat selector
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

          // weekly options
          if (_repeatPattern.frequency == RepeatFrequency.weekly) ...[
            const SizedBox(height: 12,),
            Wrap(
              spacing: 4,
              children: List.generate(7, (i) {
                final day = i + 1;
                final labels = [
                  AppStrings.text('repeat.day.short.mon'),
                  AppStrings.text('repeat.day.short.tue'),
                  AppStrings.text('repeat.day.short.wed'),
                  AppStrings.text('repeat.day.short.thu'),
                  AppStrings.text('repeat.day.short.fri'),
                  AppStrings.text('repeat.day.short.sat'),
                  AppStrings.text('repeat.day.short.sun'),
                ];
                final isSelected = _selectedWeekdays.contains(day);
                return FilterChip(label: Text(labels[i]), selected: isSelected, onSelected: (bool selected) {
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

          // const SizedBox(height: 12,),

          // monthly options
          if (_repeatPattern.frequency == RepeatFrequency.monthly) ...[
            const SizedBox(height: 12,),
            Row(children: [
              Text(AppStrings.text('alarm.day_of_month'),),
              Expanded(child: SizedBox(child: TextField(
                controller: _monthlyDayController,
                keyboardType: TextInputType.text,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r"[0-9,]"))],
                decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: AppStrings.text('alarm.day_of_month_hint')),
              ),))
            ],)
          ],

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

          // max ring attempts
          Row(children: [
            Text(AppStrings.text('alarm.custom_message'), style: const TextStyle(fontWeight: FontWeight.bold),),
            Expanded(child: TextFormField(controller: _messageController, decoration: const InputDecoration(
                isDense: true,
                border: UnderlineInputBorder()
            ), validator: (val) => val == null || val == "" ? AppStrings.text('alarm.validation.required') : null,
            ))
          ],),
        ],))
    );
  }

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
