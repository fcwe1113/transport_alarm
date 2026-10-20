import 'dart:io';
import 'dart:math';

import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/app_shell.dart';
import '../widgets/stop_routes_sheet.dart';

/// The map of the enabled locales' stops. Tapping a stop opens its routes;
/// in [pickerMode] it picks the stop for an alarm instead and returns it.
class MapScreen extends StatefulWidget {
  final bool pickerMode;

  const MapScreen({super.key, this.pickerMode = false});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  EdgeInsets _mapPadding = EdgeInsets.zero;

  GoogleMapController? _mapController;
  List<GtfsStop> _stops = [];
  Set<Marker> _visibleMarkers = {};
  bool _loading = true;
  BitmapDescriptor? _stopIcon;
  GtfsStop? _selectedPickerStop;
  final GlobalKey<NavigatorState> _nestedNavKey = GlobalKey<NavigatorState>();
  // Set once the camera has been moved to the user or to a tapped stop, so a
  // slow location fix never pulls the camera away afterwards.
  bool _cameraPlaced = false;
  // Where the user last left the map, restored on the next visit. Null when
  // the last view came from centring on their location, so losing location
  // access falls back to the stops instead of their old position.
  CameraPosition? _savedCamera;
  CameraPosition? _currentCamera;
  // Chosen once, when the map is first laid out.
  CameraPosition? _initialCamera;
  // True from starting a move to the user's location until it comes to rest.
  bool _movingToLocation = false;

  static const _stopIconAsset = "assets/icons/icon.png";
  static const _defaultCamera = CameraPosition(target: LatLng(22.3193, 114.1694), zoom: 12);
  static const _cameraLatKey = 'map_camera_lat';
  static const _cameraLngKey = 'map_camera_lng';
  static const _cameraZoomKey = 'map_camera_zoom';
  static const _cameraFromLocationKey = 'map_camera_from_location';
  // A last known fix older than this may be somewhere else entirely.
  static const _maxLastKnownAge = Duration(minutes: 10);
  // How much of the screen a stop's bottom sheet covers.
  static const _sheetHeightFraction = 0.5;
  // Most markers shown at once, so a zoomed-out map stays responsive.
  static const _maxVisibleMarkers = 50;

  @override
  void initState() {
    super.initState();
    _loadMapData();
  }

  Future<void> _loadMapData() async {
    try {
      final locales = await LocaleSelectionService().getEnabledLocales();
      final stops = <GtfsStop>[];
      for (final locale in locales.keys) {
        stops.addAll(await GtfsDatabase.forLocale(locale).getAllGtfsStops());
      }
      final savedCamera = await _loadSavedCamera();

      if (!mounted) return;
      setState(() {
        _stops = stops;
        _savedCamera = savedCamera;
        _loading = false;
      });
    } catch (e, stackTrace) {
      debugPrint("Map data load failed: $e\n$stackTrace");
    }
  }

  Future<CameraPosition?> _loadSavedCamera() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_cameraLatKey);
    final lng = prefs.getDouble(_cameraLngKey);
    final zoom = prefs.getDouble(_cameraZoomKey);
    if (lat == null || lng == null || zoom == null) return null;
    if (prefs.getBool(_cameraFromLocationKey) ?? false) return null;
    return CameraPosition(target: LatLng(lat, lng), zoom: zoom);
  }

  Future<void> _saveCamera() async {
    final camera = _currentCamera;
    final fromLocation = _movingToLocation;
    _movingToLocation = false;
    if (camera == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_cameraLatKey, camera.target.latitude);
    await prefs.setDouble(_cameraLngKey, camera.target.longitude);
    await prefs.setDouble(_cameraZoomKey, camera.zoom);
    await prefs.setBool(_cameraFromLocationKey, fromLocation);
  }

  /// A view of the user's selected stops for a map of [size], worked out here
  /// rather than with the map's own bounds fitting, which can leave the map
  /// in a broken state if it runs before the map view is laid out.
  CameraPosition? _cameraForStops(Size size) {
    // The GB import stores 0,0 for stops without coordinates.
    final stops = _stops.where((s) => s.lat != 0 || s.lng != 0).toList();
    if (stops.isEmpty || size.isEmpty) return null;

    final lats = stops.map((s) => s.lat).toList()..sort();
    final lngs = stops.map((s) => s.lng).toList()..sort();
    // Trim the outermost 2% so a few stray stops don't stretch the view;
    // small sets use every stop.
    final trim = stops.length >= 50 ? (stops.length * 0.02).floor() : 0;
    final south = lats[trim], north = lats[lats.length - 1 - trim];
    final west = lngs[trim], east = lngs[lngs.length - 1 - trim];

    // Web Mercator: the world is 256 logical pixels wide at zoom 0.
    double mercatorY(double lat) => log(tan(pi / 4 + lat * pi / 360));
    final centerY = (mercatorY(south) + mercatorY(north)) / 2;
    final center = LatLng(
      (2 * atan(exp(centerY)) - pi / 2) * 180 / pi,
      (west + east) / 2,
    );

    const padding = 48.0;
    final width = max(size.width - 2 * padding, 64.0);
    final height = max(size.height - 2 * padding, 64.0);
    final lngSpan = east - west;
    final ySpan = mercatorY(north) - mercatorY(south);
    final zoomX = lngSpan <= 0 ? 15.0 : log(width * 360 / (256 * lngSpan)) / ln2;
    final zoomY = ySpan <= 0 ? 15.0 : log(height * 2 * pi / (256 * ySpan)) / ln2;
    return CameraPosition(target: center, zoom: min(zoomX, zoomY).clamp(3.0, 15.0));
  }

  /// Moves the camera to the user's location when it's available. Without
  /// location access or a fix, the map keeps its saved or stop-fitted view.
  Future<void> _centerOnUserLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return;
      }
      // Rebuild so the map turns on its location dot now access is granted.
      if (mounted) setState(() {});

      final lastKnown = await Geolocator.getLastKnownPosition();
      final lastKnownIsRecent = lastKnown != null &&
          DateTime.now().difference(lastKnown.timestamp) < _maxLastKnownAge;
      final position = lastKnownIsRecent
          ? lastKnown
          : await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              timeLimit: Duration(seconds: 10),
            ),
          );
      // 0,0 is what some devices report before they have a real fix.
      if (position.latitude == 0 && position.longitude == 0) return;
      if (!mounted || _cameraPlaced || _mapController == null) return;
      _cameraPlaced = true;
      _movingToLocation = true;
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(position.latitude, position.longitude),
          16,
        ),
      );
    } catch (e) {
      debugPrint("Could not centre map on user location: $e");
    }
  }

  Future<BitmapDescriptor> _loadStopIcon() async {
    if (_stopIcon != null) return _stopIcon!;
    _stopIcon = await BitmapDescriptor.asset(const ImageConfiguration(size: Size(32, 32)), _stopIconAsset);
    return _stopIcon!;
  }

  Future<Set<Marker>> _buildMarkers(List<GtfsStop> stops) async {
    final icon = await _loadStopIcon();
    return {
      for (final stop in stops)
        Marker(markerId: MarkerId(stop.id), position: LatLng(stop.lat, stop.lng), icon: icon, onTap: () => _onStopTapped(stop)),
    };
  }

  /// Centres [stop] above its bottom sheet and opens the sheet: its routes,
  /// or in picker mode the routes plus picking it for the alarm.
  void _onStopTapped(GtfsStop stop) {
    _cameraPlaced = true;

    const zoom = 19.0;
    final screenHeight = MediaQuery.of(context).size.height;
    final metersPerPixel = 156543.03392 * cos(stop.lat * pi / 180) / pow(2, zoom);
    // Keeps the stop above the bottom sheet. iOS applies the bottom map
    // padding set below, which already centres the camera above the sheet,
    // so shifting the target as well would aim below the stop there. The
    // padding has no effect on Android, so it shifts the target instead.
    final latOffset = Platform.isIOS
        ? 0.0
        : ((screenHeight * _sheetHeightFraction / 2) * metersPerPixel) / 111320;

    setState(() {
      if (widget.pickerMode) _selectedPickerStop = stop;
      _mapPadding = EdgeInsets.only(bottom: screenHeight * _sheetHeightFraction);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(stop.lat - latOffset, stop.lng), zoom));
    });

    showModalBottomSheet(
        // The picker's sheet opens in the map's nested navigator, so the
        // app bar's check button stays usable above it.
        context: widget.pickerMode ? _nestedNavKey.currentContext! : context,
        barrierColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => StopRoutesSheet(stop: stop, pickerMode: widget.pickerMode)
    ).whenComplete(() {
      // Picking a stop closes the sheet and then this screen.
      if (!mounted) return;
      setState(() {
        _mapPadding = EdgeInsets.zero;
        if (widget.pickerMode) _selectedPickerStop = null;
      });
      if (!widget.pickerMode) _updateVisibleMarkers();
    });
  }

  /// Shows markers for the stops in view, up to [_maxVisibleMarkers].
  Future<void> _updateVisibleMarkers() async {
    final controller = _mapController;
    if (controller == null) return;
    final bounds = await controller.getVisibleRegion();
    final visibleStops = _stops
        .where((stop) => bounds.contains(LatLng(stop.lat, stop.lng)))
        .take(_maxVisibleMarkers)
        .toList();
    final markers = await _buildMarkers(visibleStops);
    if (!mounted) return;
    setState(() => _visibleMarkers = markers);
  }

  @override
  Widget build(BuildContext context) {
    final title = AppStrings.text(widget.pickerMode ? 'map.choose_stop' : 'map.title');
    if (_loading) {
      return AppShell(
        title: title,
        selectedTab: 1,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return AppShell(
      title: title,
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
      body: Navigator(key: _nestedNavKey, onGenerateRoute: (settings) => MaterialPageRoute(builder: (nestedContext) => LayoutBuilder(builder: (context, constraints) {
        _initialCamera ??= _savedCamera ?? _cameraForStops(constraints.biggest) ?? _defaultCamera;
        return GoogleMap(
          // Only iOS applies this padding; see _onStopTapped.
          padding: _mapPadding,
          initialCameraPosition: _initialCamera!,
          onMapCreated: (controller) {
            _mapController = controller;
            _updateVisibleMarkers();
            _centerOnUserLocation();
          },
          onCameraMove: (camera) => _currentCamera = camera,
          onCameraIdle: () {
            _updateVisibleMarkers();
            _saveCamera();
          },
          myLocationEnabled: true,
          markers: _visibleMarkers
        );
      }),),)
    );
  }
}
