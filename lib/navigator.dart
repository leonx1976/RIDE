import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'main.dart';

const LatLng _kaluga = LatLng(54.5138, 36.2754);
const String _tiles = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String _nominatim = 'https://nominatim.openstreetmap.org/search';
const String _valhalla = 'https://valhalla1.openstreetmap.de/route';
const String _osrm = 'https://routing.openstreetmap.de/routed-foot/route/v1/driving';

class NominatimPlace {
  NominatimPlace(this.name, this.point);
  final String name;
  final LatLng point;
}

class NaviPage extends StatefulWidget {
  const NaviPage({super.key});
  @override
  State<NaviPage> createState() => _NaviPageState();
}

class _NaviPageState extends State<NaviPage> {
  final MapController _map = MapController();
  final TextEditingController _searchCtrl = TextEditingController();
  StreamSubscription<Position>? _posSub;

  LatLng? _me;
  LatLng? _dest;
  String _destName = '';
  List<LatLng> _route = [];
  double? _distKm;
  double? _timeMin;
  bool _busy = false;
  bool _locDenied = false;
  List<NominatimPlace> _results = [];

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? context.c.error : null,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _initLocation() async {
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      final servicesOn = await Geolocator.isLocationServiceEnabled();
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever ||
          !servicesOn) {
        if (mounted) setState(() => _locDenied = true);
        return;
      }
      if (mounted) setState(() => _locDenied = false);

      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);
      if (!mounted) return;
      setState(() => _me = LatLng(pos.latitude, pos.longitude));
      _map.move(_me!, 15);

      await _posSub?.cancel();
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium, distanceFilter: 5),
      ).listen((pos) {
        if (mounted) setState(() => _me = LatLng(pos.latitude, pos.longitude));
      });
    } catch (_) {
      if (mounted) setState(() => _locDenied = true);
    }
  }

  void _onMapTap(TapPosition _, LatLng point) {
    setState(() {
      _dest = point;
      _destName = 'Выбранная точка';
    });
    _buildRoute();
  }

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _busy = true);
    try {
      final uri = Uri.parse(_nominatim).replace(queryParameters: {
        'q': q,
        'format': 'json',
        'limit': '6',
        'countrycodes': 'ru',
        'viewbox': '35.4,54.95,37.2,54.05',
        'bounded': '0',
      });
      final r = await http
          .get(uri, headers: {'User-Agent': 'FamilyBox/1.0'})
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 && mounted) {
        final list = jsonDecode(r.body) as List;
        _results = list.map((e) {
          final m = e as Map<String, dynamic>;
          return NominatimPlace(
            (m['display_name'] as String?) ?? '',
            LatLng(double.parse(m['lat'] as String), double.parse(m['lon'] as String)),
          );
        }).toList();
        if (_results.isEmpty) _snack('Ничего не найдено');
        setState(() {});
      }
    } catch (_) {
      _snack('Ошибка поиска', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pickResult(NominatimPlace p) {
    setState(() {
      _dest = p.point;
      _destName = p.name;
      _results = [];
    });
    _searchCtrl.clear();
    FocusScope.of(context).unfocus();
    _map.move(p.point, 16);
    _buildRoute();
  }

  Future<void> _buildRoute() async {
    if (_dest == null) return;
    final origin = _me ?? _map.camera.center;
    if (_me == null) {
      _snack('Геолокация недоступна — маршрут от центра карты');
    }
    setState(() {
      _busy = true;
      _route = [];
      _distKm = null;
      _timeMin = null;
    });

    var success = await _buildRouteValhalla(origin, _dest!);
    if (!success) {
      success = await _buildRouteOSRM(origin, _dest!);
    }

    if (!success && mounted) {
      _snack('Не удалось построить маршрут', error: true);
    }

    if (mounted) setState(() => _busy = false);
  }

  Future<bool> _buildRouteValhalla(LatLng origin, LatLng dest) async {
    try {
      final body = jsonEncode({
        'locations': [
          {'lat': origin.latitude, 'lon': origin.longitude},
          {'lat': dest.latitude, 'lon': dest.longitude},
        ],
        'costing': 'pedestrian',
        'directions_options': {'units': 'kilometers'},
      });
      final r = await http
          .post(Uri.parse(_valhalla),
              headers: {
                'Content-Type': 'application/json',
                'User-Agent': 'FamilyBox/1.0',
              },
              body: body)
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 && mounted) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final trip = j['trip'] as Map<String, dynamic>;
        final legs = trip['legs'] as List;
        final shape = (legs.first as Map<String, dynamic>)['shape'] as String;
        _route = _decodePolyline6(shape);
        final summary = trip['summary'] as Map<String, dynamic>;
        _distKm = (summary['length'] as num?)?.toDouble();
        final sec = (summary['time'] as num?)?.toDouble();
        _timeMin = sec != null ? sec / 60 : null;
        setState(() {});
        _fitRoute();
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<bool> _buildRouteOSRM(LatLng origin, LatLng dest) async {
    try {
      final coords = '${origin.longitude},${origin.latitude};${dest.longitude},${dest.latitude}';
      final uri = Uri.parse('$_osrm/$coords?overview=full&geometries=geojson&steps=false');
      final r = await http
          .get(uri, headers: {'User-Agent': 'FamilyBox/1.0'})
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 && mounted) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final routes = j['routes']
