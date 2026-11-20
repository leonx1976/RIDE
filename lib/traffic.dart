import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'compass.dart';
import 'main.dart';
import 'routes_map.dart';
import 'tiles.dart';

const _feed = 'https://bus40.su/default.aspx?target=main&action=get_devices';
const _kaluga = LatLng(54.5293, 36.2754);
const _pingColor = Color(0xFFFF2D20);

const _cTrolley = Color(0xFF2F80ED);
const _cBus = Color(0xFF3FA85F);
const _cTaxi = Color(0xFFE08A2E);
const _cTram = Color(0xFFEB5757);

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _asDbl(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
  return null;
}

double? _pick(Map m, List<String> keys) {
  for (final k in keys) {
    if (m.containsKey(k)) {
      final d = _asDbl(m[k]);
      if (d != null) return d;
    }
  }
  return null;
}

String _routeNumber(String name) {
  final m = RegExp(r'№\s*([0-9]+[^\s]*)').firstMatch(name);
  if (m != null) return m.group(1)!;
  final m2 = RegExp(r'([0-9]+[а-яa-z]?)').firstMatch(name);
  return m2 != null ? m2.group(1)! : name;
}

int _kindOf(String name, dynamic raw) {
  final t = (raw ?? '').toString().toLowerCase();
  if (t.contains('trol') || t.contains('трол')) return 0;
  if (t.contains('tram') || t.contains('трам')) return 1;
  if (t.contains('taxi') || t.contains('такси') || t.contains('marsh')) return 2;
  final n = name.toLowerCase();
  if (n.contains('троллейбус')) return 0;
  if (n.contains('трамвай')) return 1;
  if (n.contains('такси')) return 2;
  return 3;
}

Color _kindColor(int k) {
  switch (k) {
    case 0: return _cTrolley;
    case 1: return _cTram;
    case 2: return _cTaxi;
    default: return _cBus;
  }
}

String _kindName(int k) {
  switch (k) {
    case 0: return 'Троллейбус';
    case 1: return 'Трамвай';
    case 2: return 'Маршрутное такси';
    default: return 'Автобус';
  }
}

IconData _kindIcon(int k) {
  switch (k) {
    case 0: return Icons.electrical_services_rounded;
    case 1: return Icons.tram_rounded;
    case 2: return Icons.airport_shuttle_rounded;
    default: return Icons.directions_bus_filled_rounded;
  }
}

class Vehicle {
  Vehicle({required this.id, required this.pos, required this.routeId,
    required this.label, required this.routeName, required this.kind,
    this.heading, this.speed});
  final String id;
  final LatLng pos;
  final int routeId;
  final String label;
  final String routeName;
  final int kind;
  final double? heading;
  final double? speed;
}

List<Vehicle> parseVehicles(dynamic json, Map<int, String> names) {
  final out = <Vehicle>[];
  final seen = <String>{};

  void walk(dynamic node, int? rid, String? lab) {
    if (node is List) {
      for (final e in node) { walk(e, rid, lab); }
      return;
    }
    if (node is! Map) return;
    final m = node;

    var route = rid;
    var label = lab;

    final explicit = _asInt(m['route_id'] ?? m['routeId'] ?? m['marsh_id'] ??
        m['marsh'] ?? m['route']);
    if (explicit != null) route = explicit;

    final numRaw = (m['number'] ?? m['marsh_num'] ?? m['route_number'] ??
        m['route_num'] ?? m['num']);
    if (numRaw != null) {
      final s = numRaw.toString().trim();
      if (s.isNotEmpty && s.length < 12) label = s;
    }

    if (m['data'] is List) {
      walk(m['data'], _asInt(m['id']) ?? route, label);
      return;
    }

    final lat = _pick(m, ['lat', 'latitude', 'Lat', 'y', 'gps_lat']);
    final lon = _pick(m, ['lon', 'lng', 'longitude', 'Lon', 'x', 'gps_lon']);
    if (lat != null && lon != null &&
        lat.abs() <= 90 && lon.abs() <= 180 &&
        (lat.abs() > 0.01 || lon.abs() > 0.01)) {
      final name = names[route] ?? '';
      final id = (m['id'] ?? m['device_id'] ?? m['uid'] ?? m['gos_number'] ??
              '${lat}_$lon').toString();
      final key = '$route|$id';
      if (!seen.contains(key)) {
        seen.add(key);
        out.add(Vehicle(
          id: key,
          pos: LatLng(lat, lon),
          routeId: route ?? -1,
          label: label ?? (name.isEmpty ? '?' : _routeNumber(name)),
          routeName: name.isEmpty ? 'Маршрут ${label ?? "?"}' : name,
          kind: _kindOf(name, m['type'] ?? m['veh_type'] ?? m['transport']),
          heading: _pick(m, ['azimuth', 'angle', 'direction', 'course',
              'heading', 'rot', 'rotation']),
          speed: _pick(m, ['speed', 'v', 'velocity', 'spd']),
        ));
      }
      return;
    }
    for (final v in m.values) {
      if (v is List || v is Map) walk(v, route, label);
    }
  }

  walk(json, null, null);
  return out;
}

class TrafficPage extends StatefulWidget {
  const TrafficPage({super.key});
  @override
  State<TrafficPage> createState() => _TrafficPageState();
}

class _TrafficPageState extends State<TrafficPage> with TickerProviderStateMixin {
  final MapController _map = MapController();
  final CachedTileProvider _tiles = CachedTileProvider();
  final ValueNotifier<double> _rot = ValueNotifier(0);
  final ScrollController _chips = ScrollController();

  late final AnimationController _glide =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  late final AnimationController _live =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
  late final AnimationController _pingAnim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  Map<int, String> _names = {};
  List<Vehicle> _vehicles = [];
  Map<String, LatLng> _from = {};
  Timer? _timer;
  Timer? _pingTimer;
  int _interval = 10;
  bool _auto = true;
  bool _busy = false;
  String? _error;
  DateTime? _updated;
  bool _stale = false;
  bool _labels = true;
  int? _kindFilter;
  String? _routeFilter;
  Vehicle? _selected;
  LatLng? _ping;
  double _lastApplied = -999;
  bool _locBusy = false;

  @override
  void initState() {
    super.initState();
    tileRoot();
    CompassService.instance.acquire();
    CompassService.instance.addListener(_onCompass);
    _glide.addListener(() { if (mounted) setState(() {}); });
    _bootstrap();
  }

  @override
  void dispose() {
    CompassService.instance.removeListener(_onCompass);
    CompassService.instance.release();
    _timer?.cancel();
    _pingTimer?.cancel();
    _glide.dispose();
    _live.dispose();
    _pingAnim.dispose();
    _chips.dispose();
    _rot.dispose();
    super.dispose();
  }

  void _onCompass() {
    if (!mounted) return;
    final svc = CompassService.instance;
    if (!svc.autoOrient) return;
    final h = svc.heading;
    if (h == null) return;
    var d = (h - _lastApplied).abs();
    if (d > 180) d = 360 - d;
    if (d < 1.2) return;
    _lastApplied = h;
    try { _map.rotate(-h); _rot.value = -h; } catch (_) {}
  }

  Future<void> _bootstrap() async {
    try {
      final list = await loadBusRoutes();
      _names = {for (final r in list) r.id: r.name};
    } catch (_) {}
    await _refresh();
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    if (!_auto) return;
    _timer = Timer.periodic(Duration(seconds: _interval), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await http.get(Uri.parse(_feed), headers: {
        'User-Agent': 'FamilyBox/1.4',
        'Referer': 'https://bus40.su/',
        'Accept': 'application/json, text/plain, */*',
      }).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final body = utf8.decode(r.bodyBytes, allowMalformed: true).trim();
      if (body.isEmpty) throw Exception('пустой ответ');
      final dynamic data = jsonDecode(body);
      final list = parseVehicles(data, _names);
      if (!mounted) return;
      final prev = <String, LatLng>{};
      for (final v in _vehicles) {
        prev[v.id] = _displayPos(v);
      }
      setState(() {
        _from = prev;
        _vehicles = list;
        _updated = DateTime.now();
        _error = list.isEmpty ? 'Сейчас на линии нет данных о машинах' : null;
        _stale = false;
        if (_selected != null) {
          final still = list.where((e) => e.id == _selected!.id);
          _selected = still.isEmpty ? null : still.first;
        }
      });
      _glide.forward(from: 0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stale = _vehicles.isNotEmpty;
        _error = _vehicles.isEmpty
            ? 'Трекер не отвечает (${e.toString().replaceAll("Exception: ", "")})'
            : null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  LatLng _displayPos(Vehicle v) {
    final a = _from[v.id];
    if (a == null) return v.pos;
    final t = Curves.easeOutCubic.transform(_glide.value.clamp(0.0, 1.0));
    return LatLng(a.latitude + (v.pos.latitude - a.latitude) * t,
        a.longitude + (v.pos.longitude - a.longitude) * t);
  }

  List<Vehicle> get _shown {
    return _vehicles.where((v) {
      if (_kindFilter != null && v.kind != _kindFilter) return false;
      if (_routeFilter != null && v.label != _routeFilter) return false;
      return true;
    }).toList();
  }

  List<String> get _routeLabels {
    final s = <String>{};
    for (final v in _vehicles) {
      if (_kindFilter == null || v.kind == _kindFilter) s.add(v.label);
    }
    final list = s.toList();
    list.sort((a, b) {
      final na = int.tryParse(RegExp(r'^\d+').stringMatch(a) ?? '') ?? 9999;
      final nb = int.tryParse(RegExp(r'^\d+').stringMatch(b) ?? '') ?? 9999;
      return na == nb ? a.compareTo(b) : na.compareTo(nb);
    });
    return list;
  }

  Future<void> _locateMe() async {
    if (_locBusy) return;
    setState(() => _locBusy = true);
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
        _toast('Разреши доступ к геолокации в настройках', error: true);
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        _toast('Геолокация выключена на телефоне', error: true);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      if (!mounted) return;
      final me = LatLng(pos.latitude, pos.longitude);
      CompassService.instance.setGpsCourse(pos.heading, pos.speed);
      setState(() => _ping = me);
      try { _map.move(me, math.max(_map.camera.zoom, 16)); } catch (_) {}
      _pingTimer?.cancel();
      _pingTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _ping = null);
      });
    } catch (_) {
      _toast('Не удалось определить местоположение', error: true);
    } finally {
      if (mounted) setState(() => _locBusy = false);
    }
  }

  void _toast(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: error ? context.c.error : null,
      duration: const Duration(seconds: 2),
    ));
  }

  void _fitCity() {
    final pts = _shown.map(_displayPos).toList();
    if (_ping != null) pts.add(_ping!);
    if (pts.length < 2) {
      try { _map.move(_kaluga, 13); } catch (_) {}
      return;
    }
    try {
      _map.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.fromLTRB(40, 130, 40, 230)));
    } catch (_) {}
  }

  void _openScheme(Vehicle v) {
    if (v.routeId < 0) {
      _toast('Для этой машины нет привязки к маршруту');
      return;
    }
    Navigator.pushNamed(context, '/routemap',
        arguments: BusRoute(v.routeId, v.routeName));
  }

  @override
  Widget build(BuildContext context) {
    final svc = CompassService.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([svc, _live, _pingAnim]),
      builder: (context, _) {
        final shown = _shown;
        final auto = svc.autoOrient;
        return Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _kaluga,
              initialZoom: 13,
              minZoom: 3,
              maxZoom: 18,
              onTap: (_, __) { if (_selected != null) setState(() => _selected = null); },
              onPositionChanged: (_, __) {
                try { _rot.value = _map.camera.rotation; } catch (_) {}
              },
              interactionOptions: InteractionOptions(
                flags: auto
                    ? (InteractiveFlag.all & ~InteractiveFlag.rotate)
                    : InteractiveFlag.all,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: '$kTileHost/{z}/{x}/{y}.png',
                userAgentPackageName: 'ru.family.family_box',
                tileProvider: _tiles,
                maxNativeZoom: 19,
              ),
              ValueListenableBuilder<double>(
                valueListenable: _rot,
                builder: (context, rot, __) => MarkerLayer(markers: [
                  for (final v in shown)
                    Marker(
                      point: _displayPos(v),
                      width: _labels ? 54 : 34,
                      height: _labels ? 54 : 34,
                      alignment: Alignment.center,
                      child: _vehicleMarker(v, rot),
                    ),
                  if (_ping != null)
                    Marker(
                      point: _ping!, width: 90, height: 90,
                      alignment: Alignment.center,
                      child: _pingMarker(),
                    ),
                ]),
              ),
            ],
          ),
          Positioned(top: 0, left: 0, right: 0, child: _statusBar(shown.length)),
          Positioned(top: 62, left: 0, right: 0, child: _filters()),
          Positioned(right: 12, top: 150,
              child: Column(children: [
                CompassRose(
                  rotation: _rot.value,
                  active: auto,
                  onTap: () async {
                    if (auto) {
                      await svc.setAutoOrient(false);
                      _toast('Свободное вращение пальцами');
                    } else {
                      await svc.setAutoOrient(true);
                      _lastApplied = -999;
                      _onCompass();
                      _toast(svc.hasMagnetometer
                          ? 'Карта поворачивается по компасу'
                          : 'Ориентация по курсу GPS');
                    }
                  },
                ),
                const SizedBox(height: 8),
                _round(Icons.north_rounded, 'Север сверху', () {
                  svc.setAutoOrient(false);
                  try { _map.rotate(0); _rot.value = 0; } catch (_) {}
                }),
                const SizedBox(height: 8),
                _round(Icons.crop_free_rounded, 'Показать весь город', _fitCity),
                const SizedBox(height: 8),
                _round(_labels ? Icons.label_rounded : Icons.label_off_rounded,
                    'Номера маршрутов', () => setState(() => _labels = !_labels),
                    accent: _labels ? const Color(0xFF3FA85F) : null),
              ])),
          if (_selected != null)
            Positioned(left: 12, right: 12, bottom: 168, child: _detail(_selected!)),
          Positioned(left: 0, right: 0, bottom: 0, child: _dock()),
          if (_error != null && _vehicles.isEmpty)
            Positioned.fill(child: _errorPane()),
          Positioned(left: 10, bottom: 152,
              child: Text('© OpenStreetMap · bus40.su',
                  style: TextStyle(fontSize: 10, color: context.c.onSurfaceVariant))),
        ]);
      },
    );
  }

  Widget _vehicleMarker(Vehicle v, double rot) {
    final color = _kindColor(v.kind);
    final sel = _selected?.id == v.id;
    final h = v.heading;
    return GestureDetector(
      onTap: () => setState(() => _selected = v),
      child: Transform.rotate(
        angle: -rot * math.pi / 180,
        child: Stack(alignment: Alignment.center, children: [
          if (h != null)
            Transform.rotate(
              angle: h * math.pi / 180,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: Icon(Icons.play_arrow_rounded, size: 20, color: color),
              ),
            ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: _labels ? 7 : 0, vertical: 3),
            constraints: BoxConstraints(minWidth: _labels ? 26 : 16),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(_labels ? 9 : 20),
              border: Border.all(color: Colors.white, width: sel ? 2.6 : 1.6),
              boxShadow: [
                BoxShadow(
                    color: color.withOpacity(sel ? .8 : .45),
                    blurRadius: sel ? 14 : 6, spreadRadius: sel ? 1.5 : 0),
              ],
            ),
            child: _labels
                ? Text(v.label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11.5,
                        fontWeight: FontWeight.w800, height: 1.1
