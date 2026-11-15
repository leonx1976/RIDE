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
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever || !servicesOn) {
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
      final r = await http.get(uri, headers: {'User-Agent': 'FamilyBox/1.0'}).timeout(const Duration(seconds: 20));
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
    if (_me == null) _snack('Геолокация недоступна — маршрут от центра карты');
    setState(() {
      _busy = true;
      _route = [];
      _distKm = null;
      _timeMin = null;
    });

    var success = await _buildRouteValhalla(origin, _dest!);
    if (!success) success = await _buildRouteOSRM(origin, _dest!);
    if (!success && mounted) _snack('Не удалось построить маршрут', error: true);
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
      final r = await http.post(Uri.parse(_valhalla), headers: {'Content-Type': 'application/json', 'User-Agent': 'FamilyBox/1.0'}, body: body).timeout(const Duration(seconds: 20));
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
      final r = await http.get(uri, headers: {'User-Agent': 'FamilyBox/1.0'}).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 && mounted) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final routes = j['routes'] as List;
        if (routes.isEmpty) return false;
        final route = routes.first as Map<String, dynamic>;
        final geometry = route['geometry'] as Map<String, dynamic>;
        final coords = geometry['coordinates'] as List;
        _route = coords.map((c) {
          final p = c as List;
          return LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble());
        }).toList();
        final dist = (route['distance'] as num?)?.toDouble();
        _distKm = dist != null ? dist / 1000 : null;
        final dur = (route['duration'] as num?)?.toDouble();
        _timeMin = dur != null ? dur / 60 : null;
        setState(() {});
        _fitRoute();
        return true;
      }
    } catch (_) {}
    return false;
  }

  void _fitRoute() {
    if (_route.length < 2) return;
    final bounds = LatLngBounds.fromPoints(_route);
    _map.fitCamera(CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(70)));
  }

  void _clearRoute() {
    setState(() {
      _dest = null;
      _destName = '';
      _route = [];
      _distKm = null;
      _timeMin = null;
    });
  }

  void _recenter() {
    if (_me != null) {
      _map.move(_me!, 15);
    } else {
      _initLocation();
    }
  }

  List<LatLng> _decodePolyline6(String encoded) {
    final points = <LatLng>[];
    int index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      int result = 0, shift = 0, byte;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      lat += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      result = 0;
      shift = 0;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      lng += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      points.add(LatLng(lat / 1e6, lng / 1e6));
    }
    return points;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(initialCenter: _kaluga, initialZoom: 13, onTap: _onMapTap),
        children: [
          TileLayer(urlTemplate: _tiles, userAgentPackageName: 'ru.family.family_box', tileProvider: NetworkTileProvider()),
          if (_route.isNotEmpty)
            PolylineLayer(polylines: [Polyline(points: _route, color: context.c.primary, strokeWidth: 5)]),
          MarkerLayer(markers: [
            if (_me != null)
              Marker(point: _me!, width: 40, height: 40, alignment: Alignment.center, child: Icon(Icons.my_location, color: context.c.primary, size: 30)),
            if (_dest != null)
              Marker(point: _dest!, width: 44, height: 44, alignment: Alignment.bottomCenter, child: const Icon(Icons.place, color: Color(0xFFD64545), size: 40)),
          ]),
        ],
      ),
      Positioned(left: 8, bottom: 4, child: Text('© OpenStreetMap', style: TextStyle(fontSize: 10, color: context.c.onSurfaceVariant))),
      Positioned(top: 8, left: 12, right: 12, child: _buildSearchBar()),
      if (_results.isNotEmpty) Positioned(top: 70, left: 12, right: 12, child: _buildResults()),
      if (_locDenied) Positioned(top: 70, left: 12, right: 12, child: _buildLocHint()),
      if (_route.isNotEmpty) Positioned(left: 0, right: 0, bottom: 0, child: _buildRouteInfo()),
      Positioned(
        right: 14,
        bottom: _route.isNotEmpty ? 110 : 24,
        child: FloatingActionButton.small(heroTag: 'recenter', onPressed: _recenter, backgroundColor: context.c.surface, child: Icon(Icons.my_location, color: context.c.primary)),
      ),
      if (_busy) Positioned.fill(child: Container(color: Colors.black26, child: const Center(child: CircularProgressIndicator()))),
    ]);
  }

  Widget _buildSearchBar() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(color: context.c.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: context.c.outlineVariant)),
        child: Row(children: [
          Icon(Icons.search, color: context.c.onSurfaceVariant),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(hintText: 'Куда идём? (адрес или место)', border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 14)),
            ),
          ),
          IconButton(icon: Icon(Icons.clear, color: context.c.onSurfaceVariant, size: 20), onPressed: () { _searchCtrl.clear(); setState(() => _results = []); }),
          IconButton(icon: Icon(Icons.send, color: context.c.primary, size: 20), onPressed: _search),
        ]),
      );

  Widget _buildResults() => Container(
        constraints: const BoxConstraints(maxHeight: 260),
        decoration: BoxDecoration(color: context.c.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: context.c.outlineVariant)),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final r in _results)
              ListTile(
                dense: true,
                leading: Icon(Icons.place, color: context.c.onSurfaceVariant, size: 20),
                title: Text(r.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t.bodyMedium),
                onTap: () => _pickResult(r),
              ),
          ],
        ),
      );

  Widget _buildLocHint() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: context.c.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: context.c.outlineVariant)),
        child: Row(children: [
          Expanded(child: Text('Геолокация выключена. Включите её в настройках телефона.', style: context.t.bodySmall)),
          TextButton(onPressed: _initLocation, child: const Text('Повторить')),
        ]),
      );

  Widget _buildRouteInfo() {
    final dist = _distKm == null ? '—' : _distKm! < 1 ? '${(_distKm! * 1000).round()} м' : '${_distKm!.toStringAsFixed(1)} км';
    final time = _timeMin == null ? '—' : _timeMin! < 60 ? '${_timeMin!.round()} мин' : '${(_timeMin! / 60).toStringAsFixed(1)} ч';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: context.c.outlineVariant),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.1), blurRadius: 8, offset: const Offset(0, -2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(_destName, style: context.t.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)), TextButton(onPressed: _clearRoute, child: const Text('Очистить'))]),
        Row(children: [_infoChip(Icons.straighten_rounded, dist), const SizedBox(width: 16), _infoChip(Icons.directions_walk_rounded, time)]),
      ]),
    );
  }

  Widget _infoChip(IconData icon, String value) => Row(children: [
        Icon(icon, size: 18, color: context.c.primary),
        const SizedBox(width: 6),
        Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: context.c.onSurface)),
      ]);
}
