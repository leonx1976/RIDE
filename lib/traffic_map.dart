import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'compass.dart';
import 'main.dart';
import 'tiles.dart';
import 'traffic_feed.dart';

const _kaluga = LatLng(54.5293, 36.2754);
const _red = Color(0xFFFF2D20);
const _cTrolley = Color(0xFF2F80ED);
const _cBus = Color(0xFF3FA85F);
const _cTaxi = Color(0xFFE08A2E);
const _cTram = Color(0xFFEB5757);

Color _kc(int k) => k == 0 ? _cTrolley : k == 1 ? _cTram : k == 2 ? _cTaxi : _cBus;
String _kn(int k) => k == 0 ? 'Троллейбус' : k == 1 ? 'Трамвай' : k == 2 ? 'Маршрутка' : 'Автобус';
IconData _ki(int k) => k == 0
    ? Icons.electrical_services_rounded
    : k == 1 ? Icons.tram_rounded
    : k == 2 ? Icons.airport_shuttle_rounded
    : Icons.directions_bus_filled_rounded;

class TrafficMapPage extends StatefulWidget {
  const TrafficMapPage({super.key});
  @override
  State<TrafficMapPage> createState() => _TrafficMapPageState();
}

class _TrafficMapPageState extends State<TrafficMapPage>
    with TickerProviderStateMixin {
  final MapController _map = MapController();
  final CachedTileProvider _tiles = CachedTileProvider();
  final ValueNotifier<double> _rot = ValueNotifier(0);
  late final TrafficFeed _feed = TrafficFeed();
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  Timer? _pingTimer;
  LatLng? _ping;
  YVehicle? _sel;
  String? _routeFilter;
  bool _trails = true;
  bool _labels = true;
  bool _locBusy = false;
  double _lastApplied = -999;
  final Map<String, LatLng> _shownPos = {};
  Map<String, LatLng> _prev = {};
  DateTime _feedAt = DateTime.now();

  void _onFeed() {
    _prev = Map<String, LatLng>.from(_shownPos);
    _feedAt = DateTime.now();
  }

  LatLng _at(YVehicle v) {
    final a = _prev[v.id];
    if (a == null) {
      _shownPos[v.id] = v.pos;
      return v.pos;
    }
    final ms = DateTime.now().difference(_feedAt).inMilliseconds;
    final t = Curves.easeOutCubic.transform((ms / 2500).clamp(0.0, 1.0));
    final p = LatLng(a.latitude + (v.pos.latitude - a.latitude) * t,
        a.longitude + (v.pos.longitude - a.longitude) * t);
    _shownPos[v.id] = p;
    return p;
  } 

  @override
  void initState() {
    super.initState();
    tileRoot();
    _feed.addListener(_onFeed);
    CompassService.instance.acquire();
    CompassService.instance.addListener(_onCompass);
  }

  @override
  void dispose() {
    CompassService.instance.removeListener(_onCompass);
    CompassService.instance.release();
    _pingTimer?.cancel();
    _pulse.dispose();
    _rot.dispose();
    _feed.removeListener(_onFeed);
    _feed.dispose();
    super.dispose();
  }

  void _onCompass() {
    if (!mounted) return;
    final s = CompassService.instance;
    if (!s.autoOrient) return;
    final h = s.heading;
    if (h == null) return;
    var d = (h - _lastApplied) % 360;
    if (d < 0) d += 360;
    if (d > 180) d = 360 - d;
    if (_lastApplied > -360 && d < 1.0) return;
    _lastApplied = h;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try { _map.rotate(-h); _rot.value = _map.camera.rotation; } catch (_) {}
    });
  }

  void _toast(String m, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: err ? context.c.error : null,
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _locateMe() async {
    if (_locBusy) return;
    setState(() => _locBusy = true);
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
        _toast('Разреши геолокацию в настройках', err: true);
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        _toast('Геолокация выключена', err: true);
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
      _toast('Не удалось определить местоположение', err: true);
    } finally {
      if (mounted) setState(() => _locBusy = false);
    }
  }

  List<YVehicle> get _shown => _routeFilter == null
      ? _feed.vehicles
      : _feed.vehicles.where((v) => v.route == _routeFilter).toList();

  List<String> get _routes {
    final s = <String>{for (final v in _feed.vehicles) v.route};
    final l = s.toList();
    l.sort((a, b) {
      final na = int.tryParse(RegExp(r'^\d+').stringMatch(a) ?? '') ?? 9999;
      final nb = int.tryParse(RegExp(r'^\d+').stringMatch(b) ?? '') ?? 9999;
      return na == nb ? a.compareTo(b) : na.compareTo(nb);
    });
    return l;
  }

  void _fitAll() {
    final pts = _shown.map(_at).toList();
    if (_ping != null) pts.add(_ping!);
    if (pts.length < 2) { try { _map.move(_kaluga, 13); } catch (_) {} return; }
    try {
      _map.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.fromLTRB(40, 130, 70, 60)));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final svc = CompassService.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([_feed, svc, _pulse]),
      builder: (context, _) {
        final shown = _shown;
        final auto = svc.autoOrient;
        return Stack(children: [
          Positioned(left: -4000, top: -4000, width: 1280, height: 1900, child: _feed.host),
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _kaluga,
              initialZoom: 13,
              minZoom: 3,
              maxZoom: 18,
              onTap: (_, __) { if (_sel != null) setState(() => _sel = null); },
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
              if (_trails)
                PolylineLayer(polylines: [
                  for (final v in shown)
                    if (v.trail.length > 1)
                      Polyline(points: v.trail,
                          color: _kc(v.kind).withOpacity(.35), strokeWidth: 3),
                ]),
              ValueListenableBuilder<double>(
                valueListenable: _rot,
                builder: (context, rot, __) => MarkerLayer(markers: [
                  for (final v in shown)
                    Marker(point: _at(v), width: 56, height: 56,
                        alignment: Alignment.center, child: _marker(v, rot)),
                  if (_ping != null)
                    Marker(point: _ping!, width: 92, height: 92,
                        alignment: Alignment.center, child: _pingMark()),
                ]),
              ),
            ],
          ),
          Positioned(top: 0, left: 0, right: 0, child: _status(shown.length)),
          Positioned(top: 58, left: 0, right: 0, child: _chips()),
          Positioned(right: 12, top: 112, child: Column(children: [
            CompassRose(rotation: _rot.value, active: auto, onTap: () async {
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
            }),
            const SizedBox(height: 8),
            _round(Icons.north_rounded, 'Север сверху', () {
              svc.setAutoOrient(false);
              try { _map.rotate(0); _rot.value = 0; } catch (_) {}
            }),
            const SizedBox(height: 8),
            _round(Icons.my_location_rounded, 'Где я', _locateMe, accent: _red,
                busy: _locBusy),
            const SizedBox(height: 8),
            _round(Icons.crop_free_rounded, 'Весь город', _fitAll),
            const SizedBox(height: 8),
            _round(_trails ? Icons.timeline_rounded : Icons.timeline_outlined,
                'Треки', () => setState(() => _trails = !_trails),
                accent: _trails ? _cBus : null),
            const SizedBox(height: 8),
            _round(_labels ? Icons.label_rounded : Icons.label_off_rounded,
                'Номера', () => setState(() => _labels = !_labels),
                accent: _labels ? _cBus : null),
          ])),
          if (_sel != null)
            Positioned(left: 12, right: 76, bottom: 14, child: _detail(_sel!)),
          Positioned(left: 10, bottom: 4,
              child: Text('© OpenStreetMap · данные Яндекс.Транспорт',
                  style: TextStyle(fontSize: 10, color: context.c.onSurfaceVariant))),
        ]);
      },
    );
  }

  Widget _marker(YVehicle v, double rot) {
    final col = _kc(v.kind);
    final sel = _sel?.id == v.id;
    final h = v.heading;
    final layers = <Widget>[];
    if (h != null) {
      layers.add(Transform.rotate(
        angle: h * math.pi / 180,
        child: SizedBox(width: 56, height: 56,
          child: Align(alignment: Alignment.topCenter,
            child: Stack(alignment: Alignment.center, children: [
              Icon(Icons.arrow_drop_up_rounded, size: 34, color: Colors.white),
              Icon(Icons.arrow_drop_up_rounded, size: 28, color: col),
            ]))),
      ));
    }
    layers.add(Container(
      padding: EdgeInsets.symmetric(horizontal: _labels ? 8 : 0, vertical: 3),
      constraints: BoxConstraints(minWidth: _labels ? 30 : 16),
      decoration: BoxDecoration(
        color: col,
        borderRadius: BorderRadius.circular(_labels ? 9 : 20),
        border: Border.all(color: Colors.white, width: sel ? 3 : 2),
        boxShadow: [BoxShadow(color: col.withOpacity(sel ? .9 : .5),
            blurRadius: sel ? 16 : 8)],
      ),
      child: _labels
          ? Text(v.route, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13,
                  fontWeight: FontWeight.w900, height: 1.1))
          : const SizedBox(width: 8, height: 8),
    ));
    return GestureDetector(
      onTap: () => setState(() => _sel = v),
      child: Transform.rotate(angle: -rot * math.pi / 180,
          child: Stack(alignment: Alignment.center, children: layers)),
    );
  }

  Widget _pingMark() {
    final t = _pulse.value;
    return Stack(alignment: Alignment.center, children: [
      Container(width: 24 + 64 * t, height: 24 + 64 * t,
        decoration: BoxDecoration(shape: BoxShape.circle,
          border: Border.all(color: _red.withOpacity(.6 * (1 - t)), width: 2.5),
          color: _red.withOpacity(.14 * (1 - t)))),
      Container(width: 22, height: 22,
        decoration: BoxDecoration(shape: BoxShape.circle, color: _red,
          border: Border.all(color: Colors.white, width: 3.5),
          boxShadow: [BoxShadow(color: _red.withOpacity(.75), blurRadius: 16)])),
    ]);
  }

  Widget _status(int n) {
    final u = _feed.updated;
    final time = u == null ? '—'
        : '${u.hour.toString().padLeft(2, "0")}:${u.minute.toString().padLeft(2, "0")}:${u.second.toString().padLeft(2, "0")}';
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        gradient: const LinearGradient(colors: [Color(0xFF1B4FA8), Color(0xFF1E7A46)]),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.25), blurRadius: 10)],
      ),
      child: Row(children: [
        Container(width: 9, height: 9,
          decoration: BoxDecoration(shape: BoxShape.circle,
            color: _feed.running ? const Color(0xFF6BFF9E) : const Color(0xFFFFC46B),
            boxShadow: [BoxShadow(
                color: Colors.white.withOpacity(.3 * (1 - _pulse.value)),
                blurRadius: 4 + 8 * (1 - _pulse.value))])),
        const SizedBox(width: 9),
        Expanded(child: Text('$n машин · $time · опросов ${_feed.polls}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12.5,
                fontWeight: FontWeight.w600))),
        _mini(_feed.running ? Icons.pause_rounded : Icons.play_arrow_rounded,
            _feed.running ? 'Пауза' : 'Пуск', () async {
          await _feed.setRunning(!_feed.running);
          _toast(_feed.running ? 'Источник включён' : 'Источник на паузе');
        }),
        _mini(Icons.refresh_rounded, 'Обновить', () => _feed.refreshNow()),
        _mini(_feed.economy ? Icons.eco_rounded : Icons.eco_outlined,
            'Экономный режим', () async {
          await _feed.setEconomy(!_feed.economy);
          _toast(_feed.economy
              ? 'Экономный режим: тайлы Яндекса не грузятся'
              : 'Экономный режим выключен');
        }),
        _mini(_feed.headAtEnd ? Icons.swap_horiz_rounded : Icons.swap_horiz_outlined,
            'Голова трека', () {
          _feed.setHeadAtEnd(!_feed.headAtEnd);
          _toast(_feed.headAtEnd ? 'Маркер в конце трека' : 'Маркер в начале трека');
        }),
      ]),
    );
  }

  Widget _mini(IconData i, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(9),
          child: SizedBox(width: 34, height: 30,
              child: Icon(i, size: 18, color: Colors.white))),
      );

  Widget _chips() {
    final rs = _routes;
    if (rs.isEmpty) return const SizedBox.shrink();
    return SizedBox(height: 34,
      child: ListView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: [
          _chip(null, 'Все'),
          for (final r in rs) _chip(r, r),
        ]));
  }

  Widget _chip(String? v, String t) {
    final on = _routeFilter == v;
    return Padding(padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: on ? _cTaxi : context.c.surface,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(borderRadius: BorderRadius.circular(9),
          onTap: () => setState(() { _routeFilter = v; _sel = null; }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            alignment: Alignment.center,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(9),
              border: Border.all(color: on ? _cTaxi : context.c.outlineVariant)),
            child: Text(t, style: TextStyle(fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: on ? Colors.white : context.c.onSurface)),
          ))));
  }

  Widget _detail(YVehicle v) {
    final col = _kc(v.kind);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(color: context.c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: col.withOpacity(.6), width: 1.4),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.22), blurRadius: 14)]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 32, height: 32,
            decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(10)),
            child: Icon(_ki(v.kind), color: Colors.white, size: 18)),
          const SizedBox(width: 9),
          Expanded(child: Text('${_kn(v.kind)} № ${v.route}',
              style: context.t.titleMedium, maxLines: 1,
              overflow: TextOverflow.ellipsis)),
          IconButton(onPressed: () => setState(() => _sel = null),
              icon: const Icon(Icons.close_rounded, size: 18)),
        ]),
        Text('обновлено ${_feed.ageOf(v.id)} с · точек ${v.trail.length} · курс '
            '${v.heading == null ? "—" : "${v.heading!.round()}°"}',
            style: context.t.bodySmall),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: col),
            onPressed: () { try { _map.move(v.pos, math.max(_map.camera.zoom, 16)); } catch (_) {} },
            icon: const Icon(Icons.center_focus_strong_rounded, size: 16),
            label: const Text('В центр'),
          )),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () {
              if (v.trail.length < 2) return;
              try {
                _map.fitCamera(CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints(v.trail),
                    padding: const EdgeInsets.fromLTRB(40, 130, 70, 60)));
              } catch (_) {}
            },
            child: const Text('Трек'),
          ),
        ]),
      ]),
    );
  }

  Widget _round(IconData i, String tip, VoidCallback onTap,
      {Color? accent, bool busy = false}) => Tooltip(
        message: tip,
        child: Material(color: context.c.surface, shape: const CircleBorder(),
          elevation: 2,
          child: InkWell(customBorder: const CircleBorder(), onTap: onTap,
            child: Container(width: 46, height: 46,
              decoration: BoxDecoration(shape: BoxShape.circle,
                border: Border.all(color: accent ?? context.c.outlineVariant, width: 1.4)),
              child: busy
                  ? const Padding(padding: EdgeInsets.all(13),
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(i, size: 21, color: accent ?? context.c.primary)))),
      );
}
