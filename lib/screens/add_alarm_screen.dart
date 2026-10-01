import 'package:transport_alarm/models/bus_alarm.dart';
import 'package:transport_alarm/screens/map_screen.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/transit/models/bus_route.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/alarm_lifecycle_service.dart';

class AddAlarmScreen extends StatefulWidget {
  final BusAlarm? alarmToEdit;

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

  Set<BusRoute> _selectedRoutes = {};
  Set<BusRoute> _availableRoutes = {};

  RepeatPattern _repeatPattern = RepeatPattern.none;
  final Set<int> _selectedWeekdays = {1, 2, 3, 4, 5}; // 1 = mon ... 7 = sun
  late TextEditingController _monthlyDayController;
  late TextEditingController _thresholdController;
  late TextEditingController _attemptsController;
  late TextEditingController _messageController;

  bool _liveOnly = false;

  final alarmStorage = AlarmStorageService();

  @override
  void initState() {
    super.initState();
    _monthlyDayController = TextEditingController(text: DateTime.now().day.toString());
    _thresholdController = TextEditingController();
    _messageController = TextEditingController(text: "Wake Up!");
    _attemptsController = TextEditingController(text: "10");
    if (widget.alarmToEdit != null) {
      _prefillExistingAlarmData(widget.alarmToEdit!);
    } else {
      _loadBusStops();
    }
  }

  Future<void> _prefillExistingAlarmData(BusAlarm alarm) async {
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
      final routes = Set<BusRoute>.from(await db.getRoutesForGtfsStop(alarm.gtfsStopId));
      final selectedRoutes = routes.where((r) => alarm.routeNumbers.contains(r.routeNumber)).toSet();

      setState(() {
        _selectedStop = stop;
        _availableRoutes = routes;
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
    final routeList = Set<BusRoute>.from(await GtfsDatabase.forLocale("hk").getRoutesForGtfsStop(picked.id)); // todo remove locale hardcode
    setState(() {
      _selectedStop = picked;
      _availableRoutes = routeList;
      _selectedRoutes = {};
      _searchController?.text = GtfsStop.cleanStopName(_selectedStop!.name);
    });
  }

  Future<void> _compileAndSave() async {

    // errors
    bool error = false;
    String errorMsg = "";
    if (!(_formKey.currentState?.validate() ?? false)) {
      error = true;
    }
    if (_selectedStop == null) {
      error = true;
      errorMsg += "No stop selected\n";
    } else if (_selectedRoutes.isEmpty) {
      error = true;
      errorMsg += "No routes selected\n";
    }

    final days = _monthlyDayController.text;
    final splitDays = days.split(",").map((d) => int.tryParse(d)!).whereType<int>().toSet();
    if (_repeatPattern.frequency == RepeatFrequency.weekly) {
      if (_selectedWeekdays.isEmpty) {
        error = true;
        errorMsg += "No weekdays selected\n";
      }
    } else if (_repeatPattern.frequency == RepeatFrequency.monthly) {
      if (days.trim().isEmpty) {
        error = true;
        errorMsg += "No days in month selected\n";
      } else {
        final invalidDays = days.split(",").any((d) {
          final parsed = int.tryParse(d.trim());
          return parsed == null || parsed < 1 || parsed > 31;
        });
        if (invalidDays) {
          error = true;
          errorMsg += "Some days in month are invalid\n";
        }
      }
    }

    if (error) {
      if (errorMsg != "") {
        showDialog(context: context, builder: (context) => AlertDialog(
          title: const Text("Error"),
          content: Text(errorMsg),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("OK"))],
        ));
      }
      return;
    }

    // conversions, if user picked all weekdays convert to daily, etc

    if (_repeatPattern.frequency == RepeatFrequency.weekly) {
      if (_selectedWeekdays.containsAll({1, 2, 3, 4, 5, 6, 7})) _repeatPattern = RepeatPattern(frequency: RepeatFrequency.daily);
    } else if (_repeatPattern.frequency == RepeatFrequency.monthly) {
      if (splitDays.length == 31 && splitDays.first == 1 && splitDays.last == 31) _repeatPattern = RepeatPattern(frequency: RepeatFrequency.daily);
    }

    // warnings, allow user to return but can proceed if desired

    if (_calculateDurationInMinutes(_leftTime, _rightTime) > 60) {
      final proceed = await _showWarning("Setting an alarm window of over 1 hour is not recommended, make sure you know what you are doing before continuing.");
      if (proceed != true) return;
    }

    if (_repeatPattern.frequency == RepeatFrequency.monthly && (splitDays.contains(29) || splitDays.contains(30) || splitDays.contains(31))) {
      final proceed = await _showWarning("You entered days not present in every month, the alarm will not trigger on months without those days.");
      if (proceed != true) return;
    }

    final alarmThresholds = _thresholdController.text.split(",").map((t) => int.tryParse(t.trim())).whereType<int>().map(
            (m) => ThresholdState(minutesBeforeArrival: m, ringCount: int.tryParse(_attemptsController.text) ?? 10)
    ).toList();

    final newAlarm = BusAlarm(
        id: widget.alarmToEdit?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        gtfsStopId: _selectedStop!.id,
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
    if (widget.alarmToEdit != null) await lifecycle.deleteAlarm(newAlarm.id); // todo write lifecycle edit alarm method
    await lifecycle.createAlarm(newAlarm);
    Navigator.pop(context);
  }

  Future<bool?> _showWarning(String text) async {
    return showDialog(context: context, builder: (context) => AlertDialog(
      title: const Text("Warning"),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text("Go back"),),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text("Continue"))
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(title: widget.alarmToEdit != null ? "Edit Alarm" : "Add a new alarm",
        actions: [IconButton(onPressed: _compileAndSave, icon: const Icon(Icons.check))],
        body: Form(key: _formKey, child: ListView(padding: const EdgeInsets.all(16), children: [
          // time range selector slider
          Card(child: Padding(padding: const EdgeInsetsGeometry.all(16), child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text("Alarm Time Window", style: TextStyle(fontWeight: FontWeight.bold)),
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
                  child: Text("${_calculateDurationInMinutes(_leftTime, _rightTime)} min", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),),
                ), const SizedBox(height: 2,), const Icon(Icons.arrow_forward, size: 20,)
                ],),

                // right time button
                OutlinedButton.icon(onPressed: () async {
                  final picked = await showTimePicker(context: context, initialTime: _rightTime);
                  if (picked != null) _onRightTimeChanged(picked);
                }, label: Text("${_rightTime.hour.toString().padLeft(2, "0")}:${_rightTime.minute.toString().padLeft(2, "0")}"), icon: const Icon(Icons.access_time))
              ],),
              const SizedBox(height: 12,),
              Row(children: [const Text("0m"), Expanded(child: Slider(
                value: _sliderMinutes + 0.0,
                onChanged: _onSliderChanged,
                min: 0,
                max: 60,
                divisions: 60,
                label: "+${_sliderMinutes}m",
              )), const Text("+60m")],)
            ],)
          ,),),

          const SizedBox(height: 12,),

          // bus stop search bar
          Row(children: [Expanded(child: _isLoadingStops ? TextFormField(
            enabled: false,
            decoration: InputDecoration(hintText: "Loading...", prefixIcon: const SizedBox(
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
              final Set<BusRoute> _routeList = Set.from(await GtfsDatabase.forLocale("hk").getRoutesForGtfsStop(selection.id));
              setState(() {
                _selectedStop = selection;
                _availableRoutes = _routeList;
                _selectedRoutes = {};
              });
            },
            fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
              _searchController = controller;
              return TextField(
                controller: controller,
                focusNode: focusNode,
                decoration: InputDecoration(
                    hintText: "Search Bus Stop...",
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
              tooltip: "Choose on map",
            )],),
          const SizedBox(height: 16,),

          // routes checkbox list
          if (_selectedStop != null) ...[
            Card(clipBehavior: Clip.antiAlias, child: ExpansionTile(
              initiallyExpanded: false,
              title: Text(
                "Routes serving ${GtfsStop.cleanStopName(_selectedStop!.name)}",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              subtitle: Text(_selectedRoutes.isEmpty
                  ? "No routes selected"
                  : "${_selectedRoutes.length} route${_selectedRoutes.length > 1 ? "s" : ""} selected",
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),),
              children: _availableRoutes.map((r) {
                return CheckboxListTile(title: Text(r.routeNumber), subtitle: Text(r.destinationText["en"]!) ,value: _selectedRoutes.contains(r), onChanged: (bool? checked) {
                  setState(() {
                    if (checked == true) {
                      _selectedRoutes.add(r);
                    } else {
                      _selectedRoutes.remove(r);
                    }
                  });
                });
              }).toList(),
            ),),
            const SizedBox(height: 16,)
          ],

          // how early to ring
          Row(children: [
            const Text("Minutes away to ring: ", style: TextStyle(fontWeight: FontWeight.bold),),
            Expanded(child: TextFormField(controller: _thresholdController, decoration: const InputDecoration(
                isDense: true, border: UnderlineInputBorder(),
                hintText: "e.g. \"8\" or \"15,12\""
            ),
              keyboardType: TextInputType.text,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r"[0-9,]"))],
              validator: (val) {
                if (val == null || val == "") {
                  return "Required";
                }

                final currentWindow = _calculateDurationInMinutes(_leftTime, _rightTime);
                final items = val.split(",");

                for (final item in items) {
                  final minutes = int.tryParse(item);
                  if (minutes == null) {
                    return "Do not chain commas";
                  }
                  if (minutes >= currentWindow) {
                    return "number(s) exceed alarm active window";
                  }
                }

                return null;
              },
            ))
          ],),
          const SizedBox(height: 24,),

          // max ring attempts
          Row(children: [
            const Text("Max ring attempts: ", style: TextStyle(fontWeight: FontWeight.bold),),
            Expanded(child: TextFormField(controller: _attemptsController, decoration: const InputDecoration(
                isDense: true,
                border: UnderlineInputBorder()
            ), keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (val) => val == null || val == "" ? "Required" : int.parse(val) > 15 ? "Cannot exceed 15 times" : null,
            ))
          ],),
          const SizedBox(height: 24,),

          // horizontal 4 way repeat selector
          const Text("Repeat Pattern", style: TextStyle(fontWeight: FontWeight.bold),),
          const SizedBox(height: 8,),
          SegmentedButton(segments: const[
            ButtonSegment(value: RepeatPattern.none, label: Text("None")),
            ButtonSegment(value: RepeatPattern(frequency: RepeatFrequency.daily), label: Text("Daily")),
            ButtonSegment(value: RepeatPattern(frequency: RepeatFrequency.weekly), label: Text("Weekly")),
            ButtonSegment(value: RepeatPattern(frequency: RepeatFrequency.monthly), label: Text("Monthly")),
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
                final labels = ["M", "T", "W", "T", "F", "S", "S"];
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
              const Text("Day of month: "),
              Expanded(child: SizedBox(child: TextField(
                controller: _monthlyDayController,
                keyboardType: TextInputType.text,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r"[0-9,]"))],
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: "e.g. \"11,25\""),
              ),))
            ],)
          ],

          const SizedBox(height: 12,),

          // ignore schedule checkbox
          SwitchListTile(
            title: const Text("Ignore scheduled times"),
            subtitle: const Text("Only rely on real-time live GPS arrival data"),
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
            const Text("Custom Message: ", style: TextStyle(fontWeight: FontWeight.bold),),
            Expanded(child: TextFormField(controller: _messageController, decoration: const InputDecoration(
                isDense: true,
                border: UnderlineInputBorder()
            ), validator: (val) => val == null || val == "" ? "Required" : null,
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