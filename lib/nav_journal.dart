import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

const jGreen = Color(0xFF22C55E);
const jGreenDeep = Color(0xFF15803D);
const jRed = Color(0xFFFF2D20);
const jAmber = Color(0xFFF59D46);

String _two(int v) => v.toString().padLeft(2, '0');

String fmtStamp(DateTime d) =>
    '${_two(d.day)}.${_two(d.month)}.${d.year}  ${_two(d.hour)}:${_two(d.minute)}';

String fmtLen(double m) =>
    m < 1000 ? '${m.round()} м' : '${(m / 1000).toStringAsFixed(2)} км';

String fmtDur(int sec) {
  final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
}

double pathMeters(List<LatLng> p) {
  const d = Distance();
  var acc = 0.0;
  for (var i = 1; i < p.length; i++) {
    acc += d.as(LengthUnit.Meter, p[i - 1], p[i]);
  }
  return acc;
}

class NavMark {
  NavMark({required this.id, required this.name, required this.point,
      required this.at, this.on = false});
  final String id;
  String name;
  final LatLng point;
  final DateTime at;
  bool on;

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'lat': point.latitude,
        'lon': point.longitude, 'at': at.millisecondsSinceEpoch, 'on': on,
      };

  static NavMark? fromJson(Map<String, dynamic> m) {
    final lat = (m['lat'] as num?)?.toDouble();
    final lon = (m['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return NavMark(
      id: (m['id'] ?? '$lat,$lon').toString(),
      name: (m['name'] ?? 'Метка').toString(),
      point: LatLng(lat, lon),
      at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num?)?.toInt() ?? 0),
      on: m['on'] == true,
    );
  }
}

class NavTrack {
  NavTrack({required this.id, required this.name, required this.points,
      required this.at, this.on = false, this.straight = false});
  final String id;
  String name;
  final List<LatLng> points;
  final DateTime at;
  bool on;
  bool straight;

  double get meters => pathMeters(points);
  List<LatLng> get shown =>
      straight ? [points.first, points.last] : points;

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'at': at.millisecondsSinceEpoch,
        'on': on, 'straight': straight,
        'pts': points.map((p) => [p.latitude, p.longitude]).toList(),
      };

  static NavTrack? fromJson(Map<String, dynamic> m) {
    final raw = m['pts'];
    if (raw is! List || raw.length < 2) return null;
    final pts = <LatLng>[];
    for (final e in raw) {
      if (e is List && e.length >= 2) {
        final a = (e[0] as num?)?.toDouble();
        final b = (e[1] as num?)?.toDouble();
        if (a != null && b != null) pts.add(LatLng(a, b));
      }
    }
    if (pts.length < 2) return null;
    return NavTrack(
      id: (m['id'] ?? '${pts.first.latitude}').toString(),
      name: (m['name'] ?? 'Трек').toString(),
      points: pts,
      at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num?)?.toInt() ?? 0),
      on: m['on'] == true,
      straight: m['straight'] == true,
    );
  }
}

class NavJournal extends ChangeNotifier {
  NavJournal._();
  static final instance = NavJournal._();

  final List<NavMark> marks = [];
  final List<NavTrack> tracks = [];

  bool recording = false;
  String recName = '';
  int recSeconds = 0;
  double recMeters = 0;
  final List<LatLng> recPoints = [];
  Timer? _tick;
  bool _loaded = false;

  Future<File> _file() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/nav_journal.json');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        for (final e in (m['marks'] as List? ?? const [])) {
          if (e is Map<String, dynamic>) {
            final v = NavMark.fromJson(e);
            if (v != null) marks.add(v);
          }
        }
        for (final e in (m['tracks'] as List? ?? const [])) {
          if (e is Map<String, dynamic>) {
            final v = NavTrack.fromJson(e);
            if (v != null) tracks.add(v);
          }
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({
        'marks': marks.map((e) => e.toJson()).toList(),
        'tracks': tracks.map((e) => e.toJson()).toList(),
      }), flush: true);
    } catch (_) {}
  }

  String get nextMarkName => 'Метка ${marks.length + 1}';
  String get nextTrackName => 'Трек ${tracks.length + 1}';

  Future<void> addMark(String name, LatLng p) async {
    marks.insert(0, NavMark(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? nextMarkName : name.trim(),
      point: p, at: DateTime.now(), on: true,
    ));
    await _save();
    notifyListeners();
  }

  Future<void> removeMark(String id) async {
    marks.removeWhere((e) => e.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> toggleMark(String id, bool v) async {
    final i = marks.indexWhere((e) => e.id == id);
    if (i < 0) return;
    marks[i].on = v;
    await _save();
    notifyListeners();
  }

  Future<void> removeTrack(String id) async {
    tracks.removeWhere((e) => e.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> toggleTrack(String id, bool v) async {
    final i = tracks.indexWhere((e) => e.id == id);
    if (i < 0) return;
    tracks[i].on = v;
    await _save();
    notifyListeners();
  }

  Future<void> setStraight(String id, bool v) async {
    final i = tracks.indexWhere((e) => e.id == id);
    if (i < 0) return;
    tracks[i].straight = v;
    await _save();
    notifyListeners();
  }

  Future<void> setAll(bool v) async {
    for (final m in marks) { m.on = v; }
    for (final t in tracks) { t.on = v; }
    await _save();
    notifyListeners();
  }

  void startRecording(String name) {
    recName = name.trim().isEmpty ? nextTrackName : name.trim();
    recPoints.clear();
    recMeters = 0;
    recSeconds = 0;
    recording = true;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      recSeconds++;
      notifyListeners();
    });
    notifyListeners();
  }

  void feed(LatLng p) {
    if (!recording) return;
    if (recPoints.isEmpty) {
      recPoints.add(p);
      notifyListeners();
      return;
    }
    final d = const Distance().as(LengthUnit.Meter, recPoints.last, p);
    if (d < 3 || d > 400) return;
    recPoints.add(p);
    recMeters += d;
    if (recPoints.length > 6000) recPoints.removeAt(0);
    notifyListeners();
  }

  Future<NavTrack?> stopRecording() async {
    _tick?.cancel();
    _tick = null;
    recording = false;
    final pts = List<LatLng>.from(recPoints);
    final name = recName;
    recPoints.clear();
    if (pts.length < 2) {
      notifyListeners();
      return null;
    }
    final t = NavTrack(
      id: 't${DateTime.now().microsecondsSinceEpoch}',
      name: name, points: pts, at: DateTime.now(), on: true,
    );
    tracks.insert(0, t);
    await _save();
    notifyListeners();
    return t;
  }

  void cancelRecording() {
    _tick?.cancel();
    _tick = null;
    recording = false;
    recPoints.clear();
    recMeters = 0;
    recSeconds = 0;
    notifyListeners();
  }

  List<Widget> layers(double rot, double pulse) {
    final lines = <Polyline>[];
    final mk = <Marker>[];
    for (final t in tracks) {
      if (!t.on) continue;
      final pts = t.shown;
      if (pts.length < 2) continue;
      lines.add(Polyline(points: pts, color: jGreen.withOpacity(.26), strokeWidth: 10));
      lines.add(Polyline(points: pts, color: jGreenDeep, strokeWidth: 5.5));
      lines.add(Polyline(points: pts, color: jGreen, strokeWidth: 3));
      mk.add(Marker(point: pts.first, width: 52, height: 52,
          alignment: Alignment.center, child: _endpoint(rot, pulse, true)));
      mk.add(Marker(point: pts.last, width: 52, height: 52,
          alignment: Alignment.center, child: _endpoint(rot, pulse, false)));
    }
    if (recording && recPoints.length > 1) {
      lines.add(Polyline(points: recPoints, color: jRed.withOpacity(.28), strokeWidth: 9));
      lines.add(Polyline(points: recPoints, color: jRed, strokeWidth: 3.5));
    }
    for (final m in marks) {
      if (!m.on) continue;
      mk.add(Marker(point: m.point, width: 58, height: 58,
          alignment: Alignment.center, child: _markWidget(rot, pulse)));
    }
    return [
      if (lines.isNotEmpty) PolylineLayer(polylines: lines),
      if (mk.isNotEmpty) MarkerLayer(markers: mk),
    ];
  }

  Widget _markWidget(double rot, double pulse) => Transform.rotate(
        angle: -rot * math.pi / 180,
        child: Stack(alignment: Alignment.center, children: [
          Container(
            width: 22 + 34 * pulse, height: 22 + 34 * pulse,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: jGreen.withOpacity(.24 * (1 - pulse)),
              border: Border.all(
                  color: jGreen.withOpacity(.55 * (1 - pulse)), width: 2),
            ),
          ),
          Container(
            width: 24, height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [jGreen, jGreenDeep]),
              border: Border.all(color: Colors.white, width: 2.4),
              boxShadow: [BoxShadow(color: jGreen.withOpacity(.7), blurRadius: 12)],
            ),
            child: const Icon(Icons.close_rounded, size: 15, color: Colors.white),
          ),
        ]),
      );

  Widget _endpoint(double rot, double pulse, bool start) => Transform.rotate(
        angle: -rot * math.pi / 180,
        child: Stack(alignment: Alignment.center, children: [
          Container(
            width: 14 + 30 * pulse, height: 14 + 30 * pulse,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: jGreen.withOpacity(.22 * (1 - pulse)),
              border: Border.all(
                  color: jGreen.withOpacity(.5 * (1 - pulse)), width: 1.8),
            ),
          ),
          Container(
            width: 16, height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: start ? jGreen : jGreenDeep,
              border: Border.all(color: Colors.white, width: 2.2),
              boxShadow: [BoxShadow(color: jGreen.withOpacity(.6), blurRadius: 9)],
            ),
            child: start
                ? null
                : const Icon(Icons.stop_rounded, size: 9, color: Colors.white),
          ),
        ]),
      );
}