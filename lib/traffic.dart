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

    const textStyle = TextStyle(
      color: Colors.white,
      fontSize: 11.5,
      fontWeight: FontWeight.w800,
      height: 1.1,
    );

    Widget badgeChild;
    if (_labels) {
      badgeChild = Text(v.label, textAlign: TextAlign.center, style: textStyle);
    } else {
      badgeChild = const SizedBox(width: 8, height: 8);
    }

    final badge = Container(
      padding: EdgeInsets.symmetric(horizontal: _labels ? 7 : 0, vertical: 3),
      constraints: BoxConstraints(minWidth: _labels ? 26 : 16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(_labels ? 9 : 20),
        border: Border.all(color: Colors.white, width: sel ? 2.6 : 1.6),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(sel ? .8 : .45),
            blurRadius: sel ? 14 : 6,
            spreadRadius: sel ? 1.5 : 0,
          ),
        ],
      ),
      child: badgeChild,
    );

    final layers = <Widget>[];
    if (h != null) {
      layers.add(
        Transform.rotate(
          angle: h * math.pi / 180,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: Icon(Icons.play_arrow_rounded, size: 20, color: color),
          ),
        ),
      );
    }
    layers.add(badge);

    return GestureDetector(
      onTap: () => setState(() => _selected = v),
      child: Transform.rotate(
        angle: -rot * math.pi / 180,
        child: Stack(alignment: Alignment.center, children: layers),
      ),
    );
  }


  Widget _pingMarker() {
    final t = _pingAnim.value;
    return Stack(alignment: Alignment.center, children: [
      Container(
        width: 24 + 62 * t, height: 24 + 62 * t,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: _pingColor.withOpacity(.55 * (1 - t)), width: 2.5),
          color: _pingColor.withOpacity(.14 * (1 - t)),
        ),
      ),
      Container(
        width: 22, height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _pingColor,
          border: Border.all(color: Colors.white, width: 3.5),
          boxShadow: [BoxShadow(color: _pingColor.withOpacity(.7), blurRadius: 14)],
        ),
      ),
    ]);
  }

  Widget _statusBar(int count) {
    final t = _live.value;
    final time = _updated == null
        ? '—'
        : '${_updated!.hour.toString().padLeft(2, "0")}:'
          '${_updated!.minute.toString().padLeft(2, "0")}:'
          '${_updated!.second.toString().padLeft(2, "0")}';
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            const Color(0xFF1B4FA8).withOpacity(.94),
            const Color(0xFF1E7A46).withOpacity(.94),
          ],
        ),
        border: Border.all(color: Colors.white.withOpacity(.18)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.25), blurRadius: 12)],
      ),
      child: Row(children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _auto ? const Color(0xFF6BFF9E) : const Color(0xFFFFC46B),
            boxShadow: [
              BoxShadow(
                  color: (_auto ? const Color(0xFF6BFF9E) : const Color(0xFFFFC46B))
                      .withOpacity(.35 + .45 * (1 - t)),
                  blurRadius: 4 + 10 * (1 - t)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(_auto ? 'LIVE' : 'ПАУЗА',
            style: const TextStyle(color: Colors.white, fontSize: 11.5,
                fontWeight: FontWeight.w800, letterSpacing: 1.1)),
        const SizedBox(width: 12),
        Expanded(
          child: Text('$count на карте · $time',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withOpacity(.92), fontSize: 12.5)),
        ),
        if (_stale)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
                color: const Color(0xFFFFC46B), borderRadius: BorderRadius.circular(6)),
            child: const Text('нет связи',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800,
                    color: Color(0xFF3A2A05))),
          )
        else if (_busy)
          const SizedBox(width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
      ]),
    );
  }

  Widget _filters() {
    final labels = _routeLabels;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          children: [
            _kindChip(null, 'Все', Icons.layers_rounded),
            _kindChip(0, 'Троллейбус', Icons.electrical_services_rounded),
            _kindChip(3, 'Автобус', Icons.directions_bus_filled_rounded),
            _kindChip(2, 'Такси', Icons.airport_shuttle_rounded),
            _kindChip(1, 'Трамвай', Icons.tram_rounded),
          ],
        ),
      ),
      const SizedBox(height: 6),
      if (labels.isNotEmpty)
        SizedBox(
          height: 40,
          child: ScrollbarTheme(
            data: ScrollbarThemeData(
              thumbColor: MaterialStateProperty.all(const Color(0xFF2F80ED)),
              trackColor: MaterialStateProperty.all(context.c.outlineVariant),
              thickness: MaterialStateProperty.all(4),
              radius: const Radius.circular(4),
              thumbVisibility: MaterialStateProperty.all(true),
            ),
            child: Scrollbar(
              controller: _chips,
              child: ListView(
                controller: _chips,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                children: [
                  _routeChip(null, 'Все маршруты'),
                  for (final l in labels) _routeChip(l, l),
                ],
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _kindChip(int? k, String title, IconData icon) {
    final on = _kindFilter == k;
    final color = k == null ? const Color(0xFF2F80ED) : _kindColor(k);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: on ? color : context.c.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() { _kindFilter = k; _routeFilter = null; }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: on ? color : context.c.outlineVariant),
            ),
            child: Row(children: [
              Icon(icon, size: 15, color: on ? Colors.white : color),
              const SizedBox(width: 6),
              Text(title,
                  style: TextStyle(fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: on ? Colors.white : context.c.onSurface)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _routeChip(String? value, String title) {
    final on = _routeFilter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: on ? const Color(0xFFE08A2E) : context.c.surface,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: () => setState(() => _routeFilter = value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                  color: on ? const Color(0xFFE08A2E) : context.c.outlineVariant),
            ),
            child: Text(title,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                    color: on ? Colors.white : context.c.onSurface)),
          ),
        ),
      ),
    );
  }

  Widget _detail(Vehicle v) {
    final color = _kindColor(v.kind);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(.55), width: 1.4),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.22), blurRadius: 16)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(11)),
            child: Icon(_kindIcon(v.kind), color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_kindName(v.kind)} № ${v.label}', style: context.t.titleMedium,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(v.routeName, style: context.t.bodySmall,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
          IconButton(onPressed: () => setState(() => _selected = null),
              icon: const Icon(Icons.close_rounded, size: 20)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 14, runSpacing: 6, children: [
          _mini(Icons.speed_rounded,
              v.speed == null ? 'скорость —' : '${v.speed!.round()} км/ч'),
          _mini(Icons.explore_rounded,
              v.heading == null ? 'курс —' : '${v.heading!.round()}°'),
          _mini(Icons.place_rounded,
              '${v.pos.latitude.toStringAsFixed(4)}, ${v.pos.longitude.toStringAsFixed(4)}'),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: color),
              onPressed: () => _openScheme(v),
              icon: const Icon(Icons.route_rounded, size: 18),
              label: const Text('Схема маршрута'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () {
              try { _map.move(v.pos, math.max(_map.camera.zoom, 16)); } catch (_) {}
            },
            icon: const Icon(Icons.center_focus_strong_rounded, size: 18),
            label: const Text('В центр'),
          ),
        ]),
      ]),
    );
  }

  Widget _mini(IconData i, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(i, size: 14, color: context.c.onSurfaceVariant),
        const SizedBox(width: 5),
        Text(t, style: context.t.bodySmall),
      ]);

  Widget _dock() {
    final svc = CompassService.instance;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border.all(color: context.c.outlineVariant),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.2), blurRadius: 18,
            offset: const Offset(0, -3))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
            flex: 3,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _pingColor,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _locBusy ? null : _locateMe,
              icon: _locBusy
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.my_location_rounded, size: 19),
              label: Text(_ping != null ? 'Я здесь' : 'Где я',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 8),
          _dockBtn(_auto ? Icons.pause_rounded : Icons.play_arrow_rounded,
              _auto ? 'Пауза' : 'Пуск', () {
            setState(() => _auto = !_auto);
            _restartTimer();
          }, accent: _auto ? const Color(0xFF3FA85F) : const Color(0xFFE08A2E)),
          const SizedBox(width: 8),
          _dockBtn(Icons.refresh_rounded, 'Обновить', _refresh),
          const SizedBox(width: 8),
          _dockBtn(Icons.tune_rounded, 'Компас', () => showCompassCalibration(context),
              accent: svc.calibrated ? const Color(0xFF2F80ED) : null),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Icon(Icons.timer_outlined, size: 16, color: context.c.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('Обновление каждые ${_interval}с', style: context.t.bodySmall),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: const Color(0xFF2F80ED),
                inactiveTrackColor: context.c.outlineVariant,
                thumbColor: const Color(0xFFE08A2E),
                overlayColor: const Color(0xFFE08A2E).withOpacity(.18),
              ),
              child: Slider(
                value: _interval.toDouble(),
                min: 5, max: 30, divisions: 5,
                label: '${_interval}с',
                onChanged: (v) {
                  setState(() => _interval = v.round());
                  _restartTimer();
                },
              ),
            ),
          ),
        ]),
        Row(children: [
          _legend(_cTrolley, 'троллейбус'),
          const SizedBox(width: 10),
          _legend(_cBus, 'автобус'),
          const SizedBox(width: 10),
          _legend(_cTaxi, 'такси'),
          const Spacer(),
          Text(svc.calibrated ? 'компас откалиброван' : 'компас не калиброван',
              style: context.t.bodySmall),
        ]),
      ]),
    );
  }

  Widget _dockBtn(IconData icon, String tip, VoidCallback onTap, {Color? accent}) {
    return Tooltip(
      message: tip,
      child: Material(
        color: accent?.withOpacity(.14) ?? context.c.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            width: 52, height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent ?? context.c.outlineVariant, width: 1.3),
            ),
            child: Icon(icon, size: 22, color: accent ?? context.c.primary),
          ),
        ),
      ),
    );
  }

  Widget _legend(Color c, String t) => Row(children: [
        Container(width: 10, height: 10,
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 5),
        Text(t, style: context.t.bodySmall),
      ]);

  Widget _round(IconData icon, String tip, VoidCallback onTap, {Color? accent}) {
    return Tooltip(
      message: tip,
      child: Material(
        color: context.c.surface,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: accent ?? context.c.outlineVariant, width: 1.4),
            ),
            child: Icon(icon, size: 21, color: accent ?? context.c.primary),
          ),
        ),
      ),
    );
  }

  Widget _errorPane() => Container(
        color: Theme.of(context).scaffoldBackgroundColor.withOpacity(.92),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64, height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                  colors: [Color(0xFF2F80ED), Color(0xFF3FA85F)]),
            ),
            child: const Icon(Icons.sensors_off_rounded, color: Colors.white, size: 30),
          ),
          const SizedBox(height: 14),
          Text('Данные о транспорте недоступны',
              style: context.t.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(_error ?? '', style: context.t.bodySmall, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Повторить'),
          ),
        ]),
      );
}
