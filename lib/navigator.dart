import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'main.dart';
import 'tiles.dart';

const LatLng _kaluga = LatLng(54.5293, 36.2754);
const LatLng _citySW = LatLng(54.44, 36.13);
const LatLng _cityNE = LatLng(54.60, 36.42);
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
  final CachedTileProvider _tiles = CachedTileProvider();
  StreamSubscription<Position>? _posSub;

  LatLng? _me;
  LatLng? _dest;
  String _destName = '';
  List<LatLng> _route = [];
  double? _distKm;
  double? _timeMin;
  bool _busy = false;
  bool _locDenied = false;
  bool _offlineMode = false;
  double? _bearing;
  List<NominatimPlace> _results = [];
  int _cached = 0;

  @override
  void initState() {
    super.initState();
    tileRoot();
    _initLocation();
    cachedTileCount().then((n) { if (mounted) setState(() => _cached = n); });
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
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _initLocation() async {
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      final on = await Geolocator.isLocationServiceEnabled();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever || !on) {
        if (mounted) setState(() => _locDenied = true);
        return;
      }
      if (mounted) setState(() => _locDenied = false);
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
      if (!mounted) return;
      setState(() => _me = LatLng(pos.latitude, pos.longitude));
      _map.move(_me!, 15);
      await _posSub?.cancel();
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, distanceFilter: 5),
      ).listen((pos) {
        if (!mounted) return;
        setState(() => _me = LatLng(pos.latitude, pos.longitude));
        if (_offlineMode && _dest != null) _straightLine();
      });
    } catch (_) {
      if (mounted) setState(() => _locDenied = true);
    }
  }

  void _onMapTap(TapPosition _, LatLng point) {
    setState(() { _dest = point; _destName = 'Выбранная точка'; });
    _buildRoute();
  }

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _busy = true);
    try {
      final uri = Uri.parse(_nominatim).replace(queryParameters: {
        'q': q, 'format': 'json', 'limit': '6', 'countrycodes': 'ru',
        'viewbox': '35.4,54.95,37.2,54.05', 'bounded': '0',
      });
      final r = await http.get(uri, headers: {'User-Agent': 'FamilyBox/1.1'})
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 && mounted) {
        final list = jsonDecode(r.body) as List;
        _results = list.map((e) {
          final m = e as Map<String, dynamic>;
          return NominatimPlace((m['display_name'] as String?) ?? '',
              LatLng(double.parse(m['lat'] as String), double.parse(m['lon'] as String)));
        }).toList();
        if (_results.isEmpty) _snack('Ничего не найдено');
        setState(() {});
      }
    } catch (_) {
      _snack('Поиск недоступен без интернета. Отметьте цель тапом по карте.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pickResult(NominatimPlace p) {
    setState(() { _dest = p.point; _destName = p.name; _results = []; });
    _searchCtrl.clear();
    FocusScope.of(context).unfocus();
    _map.move(p.point, 16);
    _buildRoute();
  }

  void _straightLine() {
    final from = _me ?? _map.camera.center;
    final to = _dest;
    if (to == null) return;
    const d = Distance();
    final meters = d.as(LengthUnit.Meter, from, to);
    _route = [from, to];
    _distKm = meters / 1000;
    _timeMin = meters / 1000 / 4.5 * 60;
    _bearing = d.bearing(from, to);
    _offlineMode = true;
  }

  String _compass(double b) {
    const dirs = ['С', 'СВ', 'В', 'ЮВ', 'Ю', 'ЮЗ', 'З', 'СЗ'];
    return dirs[((b % 360) / 45).round() % 8];
  }

  Future<void> _buildRoute() async {
    if (_dest == null) return;
    final origin = _me ?? _map.camera.center;
    setState(() {
      _busy = true; _route = []; _distKm = null; _timeMin = null;
      _offlineMode = false; _bearing = null;
    });
    var ok = await _viaValhalla(origin, _dest!);
    if (!ok) ok = await _viaOsrm(origin, _dest!);
    if (!ok && mounted) {
      setState(_straightLine);
      _snack('Нет сети — показано направление по прямой');
      _fitRoute();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<bool> _viaValhalla(LatLng a, LatLng b) async {
    try {
      final body = jsonEncode({
        'locations': [
          {'lat': a.latitude, 'lon': a.longitude},
          {'lat': b.latitude, 'lon': b.longitude},
        ],
        'costing': 'pedestrian',
        'directions_options': {'units': 'kilometers'},
      });
      final r = await http.post(Uri.parse(_valhalla),
          headers: {'Content-Type': 'application/json', 'User-Agent': 'FamilyBox/1.1'},
          body: body).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || !mounted) return false;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final trip = j['trip'] as Map<String, dynamic>;
      final leg = (trip['legs'] as List).first as Map<String, dynamic>;
      _route = _decode6(leg['shape'] as String);
      final sum = trip['summary'] as Map<String, dynamic>;
      _distKm = (sum['length'] as num?)?.toDouble();
      final sec = (sum['time'] as num?)?.toDouble();
      _timeMin = sec != null ? sec / 60 : null;
      setState(() {});
      _fitRoute();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _viaOsrm(LatLng a, LatLng b) async {
    try {
      final c = '${a.longitude},${a.latitude};${b.longitude},${b.latitude}';
      final uri = Uri.parse('$_osrm/$c?overview=full&geometries=geojson&steps=false');
      final r = await http.get(uri, headers: {'User-Agent': 'FamilyBox/1.1'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || !mounted) return false;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final routes = j['routes'] as List;
      if (routes.isEmpty) return false;
      final route = routes.first as Map<String, dynamic>;
      final coords = (route['geometry'] as Map<String, dynamic>)['coordinates'] as List;
      _route = coords.map((e) {
        final p = e as List;
        return LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble());
      }).toList();
      final dist = (route['distance'] as num?)?.toDouble();
      _distKm = dist != null ? dist / 1000 : null;
      final dur = (route['duration'] as num?)?.toDouble();
      _timeMin = dur != null ? dur / 60 : null;
      setState(() {});
      _fitRoute();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _fitRoute() {
    if (_route.length < 2) return;
    _map.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(_route), padding: const EdgeInsets.all(70)));
  }

  void _clearRoute() {
    setState(() {
      _dest = null; _destName = ''; _route = [];
      _distKm = null; _timeMin = null; _offlineMode = false; _bearing = null;
    });
  }

  void _recenter() {
    if (_me != null) {
      _map.move(_me!, 15);
    } else {
      _initLocation();
    }
  }

  List<LatLng> _decode6(String s) {
    final pts = <LatLng>[];
    var i = 0, lat = 0, lng = 0;
    while (i < s.length) {
      var res = 0, shift = 0, byte = 0;
      do {
        byte = s.codeUnitAt(i++) - 63;
        res |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      lat += ((res & 1) != 0 ? ~(res >> 1) : (res >> 1));
      res = 0; shift = 0;
      do {
        byte = s.codeUnitAt(i++) - 63;
        res |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      lng += ((res & 1) != 0 ? ~(res >> 1) : (res >> 1));
      pts.add(LatLng(lat / 1e6, lng / 1e6));
    }
    return pts;
  }

  Future<void> _downloadDialog() async {
    final area = AreaDownload(_citySW, _cityNE, [12, 13, 14, 15, 16]);
    final total = area.total();
    var done = 0;
    var cancelled = false;
    var running = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          if (running) {
            running = false;
            area.run((d, t) {
              if (ctx.mounted) setS(() => done = d);
            }, () => cancelled).then((_) {
              if (ctx.mounted) setS(() {});
              cachedTileCount().then((n) { if (mounted) setState(() => _cached = n); });
            });
          }
          final finished = done >= total || cancelled;
          return AlertDialog(
            title: const Text('Офлайн-карта Калуги'),
            content: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Тайлов: $done из $total', style: context.t.bodyMedium),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: total == 0 ? 0 : done / total),
              const SizedBox(height: 12),
              Text(finished
                  ? (cancelled ? 'Остановлено. Скачанное сохранено.' : 'Готово. Карта работает без интернета.')
                  : 'Лучше по Wi-Fi. Около 50 МБ, несколько минут.',
                  style: context.t.bodySmall),
            ]),
            actions: [
              if (finished)
                FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть'))
              else
                TextButton(onPressed: () { cancelled = true; Navigator.pop(ctx); },
                    child: const Text('Остановить')),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(initialCenter: _kaluga, initialZoom: 13, onTap: _onMapTap),
        children: [
          TileLayer(
            urlTemplate: '$kTileHost/{z}/{x}/{y}.png',
            userAgentPackageName: 'ru.family.family_box',
            tileProvider: _tiles,
            maxNativeZoom: 19,
          ),
          if (_route.isNotEmpty)
            PolylineLayer(polylines: [
              Polyline(points: _route, color: context.c.primary, strokeWidth: 5),
            ]),
          MarkerLayer(markers: [
            if (_me != null)
              Marker(point: _me!, width: 40, height: 40, alignment: Alignment.center,
                  child: Icon(Icons.my_location, color: context.c.primary, size: 30)),
            if (_dest != null)
              Marker(point: _dest!, width: 44, height: 44, alignment: Alignment.bottomCenter,
                  child: const Icon(Icons.place, color: Color(0xFFD64545), size: 40)),
          ]),
        ],
      ),
      Positioned(left: 8, bottom: 4,
          child: Text('© OpenStreetMap · офлайн: $_cached',
              style: TextStyle(fontSize: 10, color: context.c.onSurfaceVariant))),
      Positioned(top: 8, left: 12, right: 12, child: _searchBar()),
      if (_results.isNotEmpty)
        Positioned(top: 70, left: 12, right: 12, child: _resultsBox()),
      if (_locDenied)
        Positioned(top: 70, left: 12, right: 12, child: _locHint()),
      if (_route.isNotEmpty)
        Positioned(left: 0, right: 0, bottom: 0, child: _routeInfo()),
      Positioned(
        right: 14, bottom: _route.isNotEmpty ? 130 : 24,
        child: Column(children: [
          FloatingActionButton.small(heroTag: 'dl', onPressed: _downloadDialog,
              backgroundColor: context.c.surface,
              child: Icon(Icons.download_rounded, color: context.c.primary)),
          const SizedBox(height: 10),
          FloatingActionButton.small(heroTag: 'me', onPressed: _recenter,
              backgroundColor: context.c.surface,
              child: Icon(Icons.my_location, color: context.c.primary)),
        ]),
      ),
      if (_busy)
        Positioned.fill(child: Container(color: Colors.black26,
            child: const Center(child: CircularProgressIndicator()))),
    ]);
  }

  Widget _searchBar() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(color: context.c.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.c.outlineVariant)),
        child: Row(children: [
          Icon(Icons.search, color: context.c.onSurfaceVariant),
          Expanded(child: TextField(
            controller: _searchCtrl,
            onSubmitted: (_) => _search(),
            decoration: const InputDecoration(
                hintText: 'Куда идём? Или тапните по карте',
                border: InputBorder.none, isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 14)),
          )),
          IconButton(icon: Icon(Icons.clear, size: 20, color: context.c.onSurfaceVariant),
              onPressed: () { _searchCtrl.clear(); setState(() => _results = []); }),
          IconButton(icon: Icon(Icons.send, size: 20, color: context.c.primary),
              onPressed: _search),
        ]),
      );

  Widget _resultsBox() => Container(
        constraints: const BoxConstraints(maxHeight: 250),
        decoration: BoxDecoration(color: context.c.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.c.outlineVariant)),
        child: ListView(shrinkWrap: true, children: [
          for (final r in _results)
            ListTile(dense: true,
                leading: Icon(Icons.place, size: 20, color: context.c.onSurfaceVariant),
                title: Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: context.t.bodyMedium),
                onTap: () => _pickResult(r)),
        ]),
      );

  Widget _locHint() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: context.c.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.c.outlineVariant)),
        child: Row(children: [
          Expanded(child: Text('Геолокация выключена. Включите её в настройках телефона.',
              style: context.t.bodySmall)),
          TextButton(onPressed: _initLocation, child: const Text('Повторить')),
        ]),
      );

  Widget _routeInfo() {
    final dist = _distKm == null ? '—'
        : _distKm! < 1 ? '${(_distKm! * 1000).round()} м'
        : '${_distKm!.toStringAsFixed(1)} км';
    final time = _timeMin == null ? '—'
        : _timeMin! < 60 ? '${_timeMin!.round()} мин'
        : '${(_timeMin! / 60).toStringAsFixed(1)} ч';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: context.c.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_destName, style: context.t.titleMedium,
              maxLines: 1, overflow: TextOverflow.ellipsis)),
          TextButton(onPressed: _clearRoute, child: const Text('Очистить')),
        ]),
        Row(children: [
          _chip(Icons.straighten_rounded, dist),
          const SizedBox(width: 16),
          _chip(Icons.directions_walk_rounded, time),
        ]),
        if (_offlineMode && _bearing != null)
          Padding(padding: const EdgeInsets.only(top: 8),
              child: Text('Офлайн-режим: по прямой, направление '
                  '${_compass(_bearing!)} (${_bearing!.round()}°)',
                  style: context.t.bodySmall)),
      ]),
    );
  }

  Widget _chip(IconData icon, String value) => Row(children: [
        Icon(icon, size: 18, color: context.c.primary),
        const SizedBox(width: 6),
        Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
            color: context.c.onSurface)),
      ]);
}
