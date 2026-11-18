import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart';
import 'tiles.dart';

const String _busHost = 'https://bus40.su';
const LatLng _kaluga = LatLng(54.5293, 36.2754);

const Color _cTrolley = Color(0xFF2F80ED);
const Color _cBus = Color(0xFF5CC078);
const Color _cTaxi = Color(0xFFF59D46);
const Color _cTram = Color(0xFFEB5757);

class BusRoute {
  BusRoute(this.id, this.name);
  final int id;
  final String name;
}

Future<File> _cacheFile(String name) async {
  final d = await getApplicationDocumentsDirectory();
  return File('${d.path}/$name');
}

Future<List<BusRoute>> loadBusRoutes({bool force = false}) async {
  final f = await _cacheFile('bus_routes.json');
  if (!force && await f.exists()) {
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      return list.map((e) {
        final m = e as Map<String, dynamic>;
        return BusRoute((m['id'] as num).toInt(), m['name'] as String);
      }).toList();
    } catch (_) {}
  }
  final r = await http.get(Uri.parse('$_busHost/'),
      headers: {'User-Agent': 'FamilyBox/1.1'}).timeout(const Duration(seconds: 25));
  if (r.statusCode != 200) throw Exception('site ${r.statusCode}');
  final html = utf8.decode(r.bodyBytes, allowMalformed: true);
  final re = RegExp(r'SetCurrentRoute\(this,\s*(\d+)\);">([^<]+)</a>');
  final out = <BusRoute>[];
  for (final m in re.allMatches(html)) {
    final id = int.parse(m.group(1)!);
    if (id == 0) continue;
    out.add(BusRoute(id, m.group(2)!.trim()));
  }
  if (out.isEmpty) throw Exception('no routes');
  await f.writeAsString(jsonEncode(
      out.map((e) => {'id': e.id, 'name': e.name}).toList()));
  return out;
}

Future<Map<int, Map<String, List<LatLng>>>> loadPolylines({bool force = false}) async {
  final f = await _cacheFile('bus_polylines.json');
  String? body;
  if (!force && await f.exists()) {
    try {
      body = await f.readAsString();
    } catch (_) {}
  }
  if (body == null) {
    final r = await http.get(
        Uri.parse('$_busHost/default.aspx?target=main&action=get_polylines'),
        headers: {'User-Agent': 'FamilyBox/1.1', 'Referer': '$_busHost/'})
        .timeout(const Duration(seconds: 40));
    if (r.statusCode != 200) throw Exception('polylines ${r.statusCode}');
    body = utf8.decode(r.bodyBytes, allowMalformed: true);
    try {
      await f.writeAsString(body);
    } catch (_) {}
  }
  final list = jsonDecode(body) as List;
  final out = <int, Map<String, List<LatLng>>>{};
  for (final e in list) {
    final m = e as Map<String, dynamic>;
    final id = (m['id'] as num).toInt();
    final data = m['data'] as Map<String, dynamic>?;
    if (data == null) continue;
    final dirs = <String, List<LatLng>>{};
    for (final key in ['direct', 'back']) {
      final raw = data[key] as List?;
      if (raw == null) continue;
      dirs[key] = raw.map((p) {
        final c = p as List;
        return LatLng((c[0] as num).toDouble(), (c[1] as num).toDouble());
      }).toList();
    }
    out[id] = dirs;
  }
  return out;
}

int _kind(String name) {
  final n = name.toLowerCase();
  if (n.contains('троллейбус')) return 0;
  if (n.contains('трамвай')) return 1;
  if (n.contains('такси')) return 2;
  return 3;
}

String _numberOf(String name) {
  final m = RegExp(r'№\s*([0-9]+[^\s]*)').firstMatch(name);
  if (m != null) return m.group(1)!;
  final m2 = RegExp(r'([0-9]+[а-яa-z]?(?:/[0-9]+[а-яa-z]?)*)').firstMatch(name);
  return m2 != null ? m2.group(1)! : name;
}

int _sortKey(String num) {
  final m = RegExp(r'^([0-9]+)').firstMatch(num);
  return m != null ? int.parse(m.group(1)!) : 9999;
}

Color _kindColor(int k) {
  switch (k) {
    case 0: return _cTrolley;
    case 1: return _cTram;
    case 2: return _cTaxi;
    default: return _cBus;
  }
}

String _kindTitle(int k) {
  switch (k) {
    case 0: return 'Троллейбусы';
    case 1: return 'Трамваи';
    case 2: return 'Маршрутные такси';
    default: return 'Автобусы';
  }
}

class RoutesListPage extends StatefulWidget {
  const RoutesListPage({super.key});
  @override
  State<RoutesListPage> createState() => _RoutesListPageState();
}

class _RoutesListPageState extends State<RoutesListPage> {
  late Future<List<BusRoute>> _f = loadBusRoutes();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<BusRoute>>(
        future: _f,
        builder: (context, s) {
          if (s.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (s.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.wifi_off_rounded, size: 40, color: context.c.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text('Не удалось загрузить список маршрутов',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                      onPressed: () => setState(() => _f = loadBusRoutes(force: true)),
                      child: const Text('Повторить')),
                ]),
              ),
            );
          }
          final groups = <int, List<BusRoute>>{};
          for (final r in s.data!) {
            groups.putIfAbsent(_kind(r.name), () => []).add(r);
          }
          for (final list in groups.values) {
            list.sort((a, b) =>
                _sortKey(_numberOf(a.name)).compareTo(_sortKey(_numberOf(b.name))));
          }
          final order = [0, 3, 2, 1].where(groups.containsKey).toList();
          final dark = Theme.of(context).brightness == Brightness.dark;

          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(children: [
                Expanded(child: Text('Карта маршрутов', style: context.t.titleLarge)),
                IconButton(
                    onPressed: () => setState(() => _f = loadBusRoutes(force: true)),
                    icon: const Icon(Icons.refresh_rounded)),
              ]),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                children: [
                  for (final k in order) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 10),
                      child: Row(children: [
                        Container(width: 10, height: 10,
                            decoration: BoxDecoration(color: _kindColor(k),
                                shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Text(_kindTitle(k), style: context.t.titleMedium),
                        const SizedBox(width: 8),
                        Text('${groups[k]!.length}', style: context.t.bodySmall),
                      ]),
                    ),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: groups[k]!.length,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 64,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 1,
                      ),
                      itemBuilder: (context, i) {
                        final r = groups[k]![i];
                        final num = _numberOf(r.name);
                        final col = _kindColor(k);
                        final fg = dark
                            ? Color.lerp(col, Colors.white, .25)!
                            : Color.lerp(col, Colors.black, .45)!;
                        return Material(
                          color: col.withOpacity(dark ? .22 : .14),
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => Navigator.pushNamed(context, '/routemap',
                                arguments: r),
                            onLongPress: () =>
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(r.name),
                              duration: const Duration(seconds: 2),
                            )),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: col.withOpacity(.55)),
                              ),
                              alignment: Alignment.center,
                              padding: const EdgeInsets.all(2),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(num,
                                    style: TextStyle(fontSize: 17,
                                        fontWeight: FontWeight.w600, color: fg)),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ]);
        },
      );
}

class RouteMapPage extends StatefulWidget {
  const RouteMapPage({super.key, required this.route});
  final BusRoute route;
  @override
  State<RouteMapPage> createState() => _RouteMapPageState();
}

class _RouteMapPageState extends State<RouteMapPage> {
  final MapController _map = MapController();
  final CachedTileProvider _tiles = CachedTileProvider();
  late Future<Map<int, Map<String, List<LatLng>>>> _f = loadPolylines();
  bool _showBack = true;
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    tileRoot();
  }

  void _fit(List<LatLng> pts) {
    if (pts.length < 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        _map.fitCamera(CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(pts),
            padding: const EdgeInsets.all(40)));
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<Map<int, Map<String, List<LatLng>>>>(
        future: _f,
        builder: (context, s) {
          if (s.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (s.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.wifi_off_rounded, size: 40, color: context.c.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text('Не удалось загрузить схему маршрута',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                      onPressed: () {
                        _fitted = false;
                        setState(() => _f = loadPolylines(force: true));
                      },
                      child: const Text('Повторить')),
                ]),
              ),
            );
          }
          final dirs = s.data![widget.route.id];
          if (dirs == null || dirs.isEmpty) {
            return Center(
                child: Text('Для этого маршрута нет схемы', style: context.t.bodyMedium));
          }
          final direct = dirs['direct'] ?? <LatLng>[];
          final back = dirs['back'] ?? <LatLng>[];
          final all = [...direct, if (_showBack) ...back];
          if (!_fitted && all.length > 1) {
            _fitted = true;
            _fit(all);
          }
          final lineColor = _kindColor(_kind(widget.route.name));
          return Stack(children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                  initialCenter: all.isEmpty ? _kaluga : all.first, initialZoom: 13),
              children: [
                TileLayer(
                  urlTemplate: '$kTileHost/{z}/{x}/{y}.png',
                  userAgentPackageName: 'ru.family.family_box',
                  tileProvider: _tiles,
                  maxNativeZoom: 19,
                ),
                PolylineLayer(polylines: [
                  if (_showBack && back.length > 1)
                    Polyline(points: back, color: const Color(0xFFE08A2E), strokeWidth: 4),
                  if (direct.length > 1)
                    Polyline(points: direct, color: lineColor, strokeWidth: 5),
                ]),
                MarkerLayer(markers: [
                  if (direct.isNotEmpty)
                    Marker(
                        point: direct.first,
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        child: Icon(Icons.trip_origin, color: lineColor, size: 22)),
                  if (direct.isNotEmpty)
                    Marker(
                        point: direct.last,
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        child: const Icon(Icons.flag_rounded,
                            color: Color(0xFFD64545), size: 22)),
                ]),
              ],
            ),
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                    color: context.c.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: context.c.outlineVariant)),
                child: Row(children: [
                  Expanded(
                      child: Text(widget.route.name,
                          style: context.t.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  TextButton(
                      onPressed: () {
                        _fitted = false;
                        setState(() => _showBack = !_showBack);
                      },
                      child: Text(_showBack ? 'Только туда' : 'Оба направления')),
                ]),
              ),
            ),
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: context.c.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: context.c.outlineVariant)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _legend(lineColor, 'прямое направление'),
                  if (_showBack) _legend(const Color(0xFFE08A2E), 'обратное направление'),
                ]),
              ),
            ),
            Positioned(
                right: 8,
                bottom: 4,
                child: Text('© OpenStreetMap · bus40.su',
                    style: TextStyle(fontSize: 10, color: context.c.onSurfaceVariant))),
          ]);
        },
      );

  Widget _legend(Color color, String text) => Row(children: [
        Container(width: 16, height: 4, color: color),
        const SizedBox(width: 6),
        Text(text, style: context.t.bodySmall),
      ]);
}
