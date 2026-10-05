import 'dart:math';

import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../widgets/app_shell.dart';
import '../widgets/stop_routes_sheet.dart';

/// StatefulWidget wrapper for the map screen
class MapScreen extends StatefulWidget { // statefulwidgets are widgets that can have modifiable internal data, they contain an immutable Widget and a mutable State object within
  final bool pickerMode;

  const MapScreen({super.key, this.pickerMode = false});

  @override // this is a requirement for any statefulwidget
  State<MapScreen> createState() => _MapScreenState(); // MapScreen being the immutable widget and _MapScreenState() being the mutable state
}

/// State object within the map screen
class _MapScreenState extends State<MapScreen> {
  // here State<MapScreen> DOES NOT mean a state object of a mapscreen type ala c#
  // instead it is extending the underlying State<T> and hooking up this state to the mapscreen widget

  EdgeInsets _mapPadding = EdgeInsets.zero;

  GoogleMapController? _mapController;
  static const mapsApiKey = String.fromEnvironment('MAPS_API_KEY');
  // final Map<String, BitmapDescriptor> _iconCache = {};
  List<GtfsStop> _stops = [];
  final Map<String, TransportRoute> _routesById = {};
  final Set<Marker> _markers = {};
  Set<Marker> _visibleMarkers = {};
  bool _loading = true;
  GtfsStop? selectedStop;
  final Set<Polyline> _routePolylines = {};
  BitmapDescriptor? _stopIcon;
  GtfsStop? _selectedPickerStop;
  final GlobalKey<NavigatorState> _nestedNavKey = GlobalKey<NavigatorState>();

  static const _stopIconAsset = "assets/icons/icon.png";

  @override
  void initState() {
    super.initState();
    _loadMapData();
  }

  Future<void> _loadMapData() async {
    try {
      final locales = await LocaleSelectionService().getEnabledLocales();
      final stops = <GtfsStop>[];
      for (final locale in locales) {
        stops.addAll(await GtfsDatabase.forLocale(locale).getAllGtfsStops());
      }

      setState(() {
        _stops = stops;
        _loading = false;
      });
    } catch (e, stackTrace) {
      print("Map data load failed: $e");
      print(stackTrace);
    }
  }

  Future<BitmapDescriptor> _loadStopIcon() async {
    if (_stopIcon != null) return _stopIcon!;
    _stopIcon = await BitmapDescriptor.asset(const ImageConfiguration(size: Size(32, 32)), _stopIconAsset);
    return _stopIcon!;
  }

  Future<Set<Marker>> _buildMarkers(List<GtfsStop> stops) async {
    final markers = <Marker>{};
    for (final stop in stops) {
      // if (!stop.isResolved) continue;
      final icon = _loadStopIcon();
      markers.add(Marker(markerId: MarkerId(stop.id), position: LatLng(stop.lat, stop.lng), icon: await icon, onTap: () => _onStopTapped(stop)));
    }
    return markers;
  }

  void _onStopTapped(GtfsStop stop) async {

    const zoom = 19.0;
    final screenHeight = MediaQuery.of(context).size.height;
    final sheetHeightFraction = 0.5;
    final metersPerPixel = 156543.03392 * cos(stop.lat * pi / 180) / pow(2, zoom);
    final latOffset = ((screenHeight * sheetHeightFraction / 2) * metersPerPixel) / 111320;

    if (widget.pickerMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(stop.lat - latOffset, stop.lng), zoom));
      });
      setState(() {
        _selectedPickerStop = stop;
        _mapPadding = EdgeInsets.only(bottom: MediaQuery.of(context).size.height * 0.5); // 0.4
      });
      showModalBottomSheet(
          context: _nestedNavKey.currentContext!,
          barrierColor: Colors.transparent,
          isScrollControlled: true,
          builder: (context) => StopRoutesSheet(stop: stop, pickerMode: true)
      ).whenComplete(() {setState(() => _mapPadding = EdgeInsets.zero); _selectedPickerStop = null;});
      return;
    }

    setState(() {
      _mapPadding = EdgeInsets.only(bottom: MediaQuery.of(context).size.height * 0.5);
      // selectedStop = stop;
    });
    // await _updateVisibleMarkers();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(stop.lat - latOffset, stop.lng), zoom));
    });

    showModalBottomSheet(
        context: context,
        // backgroundColor: Colors.transparent,
        barrierColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => StopRoutesSheet(stop: stop)
    ).whenComplete(() async {
      setState(() => _mapPadding = EdgeInsets.zero);
      selectedStop = null;
      await _updateVisibleMarkers();
    });
  }

  Future<void> _updateVisibleMarkers() async {
    if (_mapController == null) return;
    if (selectedStop != null) {
      setState(() async => _visibleMarkers = (await _buildMarkers([?selectedStop])));
      return;
    }

    final bounds = await _mapController!.getVisibleRegion();
    final visibleStops = _stops.where((stop) {
      // if (!stop.isResolved) return false;
      return bounds.contains(LatLng(stop.lat, stop.lng));
    }).toList();

    // hard cap the stops displayed within the visible area
    final cappedStops = visibleStops.take(50).toList();
    final markers = await _buildMarkers(cappedStops);
    setState(() => _visibleMarkers = markers);
  }

  // initial position of the map on load, currently on london, replace with user settings later
  // static const _initialPosition = CameraPosition(target: LatLng(51.5072, -0.1276), zoom: 13);

  @override // this is a requirement for any state object
  Widget build(BuildContext context) {
    // when build gets called the widget refreshes, and the statefulwidget is destroyed and rebuilt
    // there are a few ways to proc build()
    // 1. on first build
    // 2. with setState()
    // 3. rebuilding the parent widget
    // 4. hot reload in dev mode (but thats cheating)
    // for the "refresh after api pull" effect put in a setState() in the same function as the api call and put it after the api call line
    // if real time updates needed try StreamBuilder
    if (_loading) {
      return AppShell(
        title: AppStrings.text(widget.pickerMode ? 'map.choose_stop' : 'map.title'),
        selectedTab: 1,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return AppShell(
      title: AppStrings.text(widget.pickerMode ? 'map.choose_stop' : 'map.title'),
      selectedTab: 1,
      actions: widget.pickerMode ? [
        IconButton(icon: _selectedPickerStop == null ? const Icon(Icons.arrow_back) : const Icon(Icons.check), onPressed: () {
          final mapRoute = ModalRoute.of(context);
          if (mapRoute != null && !mapRoute.isCurrent) { // pop stop_route_sheet first if still present
            Navigator.of(context).pop();
          }
          Navigator.pop(context, _selectedPickerStop);
        },),
      ] : null,
      body: Navigator(key: _nestedNavKey, onGenerateRoute: (settings) => MaterialPageRoute(builder: (nestedContext) => GoogleMap(
          padding: _mapPadding, // not working for some reason
          initialCameraPosition: const CameraPosition(target: LatLng(22.3193, 114.1694), zoom: 12),
          onMapCreated: (controller) {
            _mapController = controller;
            _updateVisibleMarkers();
          },
          onCameraIdle: _updateVisibleMarkers,
          myLocationEnabled: true, // enables phone location services
          markers: _visibleMarkers
      ),),)
    );
  }
}
