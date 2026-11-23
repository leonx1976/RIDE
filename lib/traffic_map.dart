import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'compass.dart';
import 'main.dart';
import 'tiles.dart';
import 'traffic_anim.dart';
import 'traffic_feed.dart';

const _kaluga = LatLng(54.5293, 36.2754);
const _red = Color(0xFFFF2D20);
const _cTrolley = Color(0xFF2F80ED);
const _cBus = Color(0xFF3FA85F);
const _cTaxi = Color(0xFFE08A2E);
const _cTram = Color(0xFFEB5757);

Color _kc(int k) => k == 0 ? _cTrolley : k == 1 ? _cTram : k == 2 ? _cTaxi : _cBus;
String _kn(int k) =>
    k == 0 ? 'Троллейбус' : k == 1 ? 'Трамвай' : k == 2 ? 'Маршрутка' : 'Автобус';
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
  final ValueNotifier<int> _frame = ValueNotifier(0);
  final ScrollController _chips = ScrollController();
  final Map<String, TrackAnim> _tracks = {};
  late final TrafficFeed _feed = TrafficFeed();
  late final Ticker _ticker;

  Duration _last = Duration.zero;
  Timer? _pingTimer;
  LatLng? _ping;
  String? _selId;
  String? _routeFilter;
  bool _locBusy = false;
  double _lastApplied = -999;

  @override
  void initState() {
    super.initState();
    tileRoot();
    _feed.addListener(_onFeed);
    CompassService.instance.acquire();
    CompassService.instance.addListener(_onSvc);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _feed.removeListener(_onFeed);
    CompassService.instance.removeListener(_onSvc);
    CompassService.instance.release();
    _pingTimer?.cancel();
    _chips.dispose();
    _rot.dispose();
    _frame.dispose();
    _feed.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 0.016
        : (elapsed - _last).inMicroseconds / 1000000.0;
    _last = elapsed;
    final step = dt < 0 ? 0.0 : (dt > 0.1 ? 0.1 : dt);
    for (final t in _tracks.values) {
      t.advance(step);
    }
    _frame.value++;
  }

  void _onFeed() {
    final alive = <String>{};
    for (final v in _feed.vehicles) {
      alive.add(v.id);
      final t = _tracks[v.id];
      if (t == null) {
        _tracks[v.id] = TrackAnim(v.trail);
      } else {
        t.rebase(v.trail, t.pos);
      }
    }
    _tracks.removeWhere((k, _) => !alive.contains(k));
    if (_selId != null && !alive.contains(_selId)) _selId = null;
    if (mounted) setState(() {});
  }

  void _onSvc() {
    if (mounted) setState(() {});
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
      try {
        _map.rotate(-h);
        _rot.value = _map.camera.rotation;
      } catch (_) {}
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

  int _countOf(String r) => _feed.vehicles.where((v) => v.route == r).length;

  void _fitAll() {
    final pts = <LatLng>[];
    for (final v in _shown) {
      final t = _tracks[v.id];
      if (t != null) pts.add(t.pos);
    }
    if (_ping != null) pts.add(_ping!);
    if (pts.length < 2) {
      try { _map.move(_kaluga, 13); } catch (_) {}
      return;
    }
    try {
      _map.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.fromLTRB(40, 90, 76, 90)));
    } catch (_) {}
  }

  void _zoom(double d) {
    try {
      final c = _map.camera;
      _map.move(c.center, (c.zoom + d).clamp(3.0, 18.0));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final svc = CompassService.instance;
    final auto = svc.autoOrient;
    final shown = _shown;
    final sel = _selId == null
        ? null
        : _feed.vehicles.where((v) => v.id == _selId).cast<YVehicle?>().firstOrNull;
    return Stack(children: [
      Positioned(left: -4000, top: -4000, width: 1280, height: 1900, child: _feed.host),
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: _kaluga,
          initialZoom: 13,
          minZoom: 3,
          maxZoom: 18,
          onTap: (_, __) { if (_selId != null) setState(() => _selId = null); },
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
          AnimatedBuilder(
            animation: Listenable.merge([_frame, _rot]),
            builder: (context, _) {
              final rot = _rot.value;
              final marks = <Marker>[];
              for (final v in shown) {
                final t = _tracks[v.id];
                if (t == null) continue;
                marks.add(Marker(
                    point: t.pos,
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    child: _marker(v, t, rot)));
              }
              if (_ping != null) {
                marks.add(Marker(
                    point: _ping!,
                    width: 92,
                    height: 92,
                    alignment: Alignment.center,
                    child: _pingMark()));
              }
              return MarkerLayer(markers: marks);
            },
          ),
        ],
      ),
      Positioned(top: 0, left: 0, right: 0, child: _topBar()),
      Positioned(right: 12, top: 78, child: Column(children: [
        CompassRose(rotation: _rot.value, active: auto, onTap: () async {
          if (auto) {
            await svc.setAutoOrient(false);
            _toast('Свободное вращение пальцами');
          } else {
            await svc.setAutoOrient(true);
            _lastApplied = -999;
            _onSvc();
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
        _round(Icons.my_location_rounded, 'Где я', _locateMe,
            accent: _red, busy: _locBusy),
        const SizedBox(height: 8),
        _round(Icons.crop_free_rounded, 'Весь город', _fitAll),
        const SizedBox(height: 8),
        _round(Icons.add_rounded, 'Приблизить', () => _zoom(1)),
        const SizedBox(height: 8),
        _round(Icons.remove_rounded, 'Отдалить', () => _zoom(-1)),
      ])),
      if (sel != null)
        Positioned(left: 0, right: 0, bottom: 0, child: _detail(sel)),
      if (_feed.vehicles.isEmpty)
        Positioned(left: 20, right: 76, top: 90, child: _empty()),
      Positioned(left: 10, bottom: 4,
          child: Text('© OpenStreetMap · данные Яндекс.Транспорт',
              style: TextStyle(fontSize: 10, color: context.c.onSurfaceVariant))),
    ]);
  }

  Widget _marker(YVehicle v, TrackAnim t, double rot) {
    final col = _kc(v.kind);
    final sel = _selId == v.id;
    final h = t.heading;
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      constraints: const BoxConstraints(minWidth: 30),
      decoration: BoxDecoration(
        color: col,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white, width: sel ? 3 : 2),
        boxShadow: [BoxShadow(color: col.withOpacity(sel ? .9 : .5),
            blurRadius: sel ? 16 : 8)],
      ),
      child: Text(v.route, textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 13,
              fontWeight: FontWeight.w900, height: 1.1)),
    ));
    return GestureDetector(
      onTap: () => setState(() => _selId = v.id),
      child: Transform.rotate(angle: -rot * math.pi / 180,
          child: Stack(alignment: Alignment.center, children: layers)),
    );
  }

  Widget _pingMark() {
    final t = (DateTime.now().millisecondsSinceEpoch % 1200) / 1200.0;
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

  Widget _topBar() {
    final routes = _routes;
    final count = _routeFilter == null
        ? _feed.vehicles.length
        : _countOf(_routeFilter!);
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      height: 46,
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.c.outlineVariant),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.22), blurRadius: 12)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Stack(children: [
          Positioned.fill(
            child: ScrollbarTheme(
              data: ScrollbarThemeData(
                thumbColor: WidgetStateProperty.all(_cTrolley),
                trackColor: WidgetStateProperty.all(context.c.outlineVariant),
                thickness: WidgetStateProperty.all(3),
                radius: const Radius.circular(3),
                thumbVisibility: WidgetStateProperty.all(true),
              ),
              child: Scrollbar(
                controller: _chips,
                child: ListView(
                  controller: _chips,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 76, right: 10, bottom: 3),
                  children: [for (final r in routes) _chip(r)],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 62,
            child: Container(color: context.c.surface, child: _allChip(count)),
          ),
          Positioned(
            left: 60,
            top: 0,
            bottom: 0,
            width: 16,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    context.c.surface,
                    context.c.surface.withOpacity(0),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _allChip(int count) {
    final all = _routeFilter == null;
    return InkWell(
      onTap: () => setState(() {
        _routeFilter = null;
        _selId = null;
      }),
      child: Container(
        margin: const EdgeInsets.all(6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: all
                ? [const Color(0xFF1B4FA8), const Color(0xFF1E7A46)]
                : [const Color(0xFFB4661A), const Color(0xFFE08A2E)],
          ),
          border: Border.all(color: Colors.white.withOpacity(.22)),
          boxShadow: [
            BoxShadow(
                color: (all ? _cTrolley : _cTaxi).withOpacity(.42),
                blurRadius: 8),
          ],
        ),
        child: Text('$count',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w900,
                height: 1.05)),
      ),
    );
  }

  Widget _chip(String r) {
    final on = _routeFilter == r;
    final matches = _feed.vehicles.where((v) => v.route == r);
    final col = _kc(matches.isEmpty ? 3 : matches.first.kind);
    return Padding(
      padding: const EdgeInsets.only(right: 5, top: 6, bottom: 3),
      child: Material(
        color: on ? col : col.withOpacity(.12),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: () => setState(() {
            _routeFilter = r;
            _selId = null;
          }),
          child: Container(
            width: 44,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: on ? col : col.withOpacity(.5)),
              boxShadow: on
                  ? [BoxShadow(color: col.withOpacity(.45), blurRadius: 8)]
                  : null,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(r,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      height: 1.05,
                      color: on ? Colors.white : context.c.onSurface)),
            ),
          ),
        ),
      ),
    );
  }
  Widget _detail(YVehicle v) {
    final col = _kc(v.kind);
    final info = _feed.resolve(v);
    return AnimatedBuilder(
      animation: _frame,
      builder: (context, _) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: col.withOpacity(.65), width: 1.5),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(.28), blurRadius: 18)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(color: col,
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(_ki(v.kind), color: Colors.white, size: 21),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(info.title,
                    style: context.t.titleMedium,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis),
              ),
            ),
            IconButton(onPressed: () => setState(() => _selId = null),
                icon: const Icon(Icons.close_rounded, size: 20)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: col.withOpacity(.16),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: col.withOpacity(.5)),
              ),
              child: Text('№ ${v.route}',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900,
                      color: context.c.onSurface)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${_kn(v.kind)} · обновлено ${_feed.ageOf(v.id)} с',
                  style: context.t.bodySmall,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text(info.note,
                style: context.t.bodySmall,
                maxLines: 2, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: col),
              onPressed: () {
                final t = _tracks[v.id];
                if (t == null) return;
                try { _map.move(t.pos, math.max(_map.camera.zoom, 16)); } catch (_) {}
              },
              icon: const Icon(Icons.center_focus_strong_rounded, size: 17),
              label: const Text('В центр'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _empty() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.c.outlineVariant),
        ),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Ждём машины с линии', style: context.t.titleMedium),
          const SizedBox(height: 6),
          Text(_feed.error ?? 'Источник подключается, первые данные обычно приходят за 10–20 секунд.',
              style: context.t.bodySmall),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => _feed.refreshNow(),
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('Обновить'),
          ),
        ]),
      );

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

