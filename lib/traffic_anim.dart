import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

const _deg = math.pi / 180.0;

double approxMeters(LatLng a, LatLng b) {
  final k = math.cos((a.latitude + b.latitude) * 0.5 * _deg);
  final dx = (a.longitude - b.longitude) * k * 111320.0;
  final dy = (a.latitude - b.latitude) * 110540.0;
  return math.sqrt(dx * dx + dy * dy);
}

double _segT(LatLng a, LatLng b, LatLng p) {
  final k = math.cos(a.latitude * _deg);
  final ax = a.longitude * k, ay = a.latitude;
  final bx = b.longitude * k, by = b.latitude;
  final px = p.longitude * k, py = p.latitude;
  final dx = bx - ax, dy = by - ay;
  final len = dx * dx + dy * dy;
  if (len <= 1e-12) return 0;
  final t = ((px - ax) * dx + (py - ay) * dy) / len;
  return t < 0 ? 0 : (t > 1 ? 1 : t);
}

class TrackAnim {
  TrackAnim(List<LatLng> p) {
    _set(p);
    s = 0;
    limit = 0;
    v = 0;
    _sample();
  }

  List<LatLng> path = const [];
  List<double> cum = const [];
  List<double> bear = const [];
  List<LatLng>? _pending;

  double total = 0;
  double s = 0;
  double limit = 0;
  double v = 0;
  LatLng pos = const LatLng(0, 0);
  double? heading;

  void _set(List<LatLng> p) {
    if (p.isEmpty) {
      path = const [LatLng(0, 0), LatLng(0, 0)];
    } else if (p.length == 1) {
      path = [p.first, p.first];
    } else {
      path = p;
    }
    final n = path.length;
    final c = List<double>.filled(n, 0);
    final b = List<double>.filled(n - 1, 0);
    var acc = 0.0;
    for (var i = 1; i < n; i++) {
      acc += approxMeters(path[i - 1], path[i]);
      c[i] = acc;
      final dy = path[i].latitude - path[i - 1].latitude;
      final dx = (path[i].longitude - path[i - 1].longitude) *
          math.cos(path[i].latitude * _deg);
      b[i - 1] = (math.atan2(dx, dy) / _deg + 360) % 360;
    }
    cum = c;
    bear = b;
    total = acc;
  }

  double _project(LatLng p) {
    if (path.length < 2) return 0;
    var best = double.infinity;
    var bestS = 0.0;
    for (var i = 0; i < path.length - 1; i++) {
      final a = path[i], b = path[i + 1];
      final t = _segT(a, b, p);
      final q = LatLng(a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t);
      final d = approxMeters(p, q);
      if (d < best) {
        best = d;
        bestS = cum[i] + (cum[i + 1] - cum[i]) * t;
      }
    }
    return bestS;
  }

  /// Цель — голова свежего ответа Яндекса, спроецированная на текущую геометрию.
  /// Дальше этой точки маркер не уходит никогда.
  void rebase(List<LatLng> fresh, LatLng current) {
    if (fresh.isEmpty) return;
    if (path.length < 2 || total <= 0) {
      _set(fresh);
      s = 0;
      limit = 0;
      v = 0;
      _pending = null;
      _sample();
      return;
    }
    final head = fresh.first;
    final sT = _project(head);
    final exhausted = sT > total - 2 && approxMeters(path.last, head) > 10;
    if (exhausted) {
      _set(fresh);
      s = _project(current);
      limit = s;
      _pending = null;
      _sample();
      return;
    }
    limit = sT > s ? sT : s;
    _pending = fresh;
  }

  void advance(double dt, {double horizon = 3.0, double vMax = 14.0}) {
    if (path.length < 2) return;
    final remaining = limit - s;
    var target = remaining <= 0.5 ? 0.0 : remaining / horizon;
    if (target > vMax) target = vMax;
    final alpha = 1 - math.exp(-dt / 0.6);
    v += (target - v) * alpha;
    if (v < 0.02) v = 0;
    s += v * dt;
    if (s >= limit) {
      s = limit;
      v = 0;
    }
    if (s < 0) s = 0;
    _sample();

    final next = _pending;
    if (next != null && limit - s < 0.5) {
      _pending = null;
      _set(next);
      s = _project(pos);
      limit = s;
      v = 0;
      _sample();
    }
  }

  void _sample() {
    if (path.length < 2) {
      pos = path.isEmpty ? const LatLng(0, 0) : path.first;
      heading = null;
      return;
    }
    var i = 0;
    while (i < cum.length - 2 && cum[i + 1] < s) {
      i++;
    }
    final seg = cum[i + 1] - cum[i];
    var t = seg <= 1e-9 ? 0.0 : (s - cum[i]) / seg;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final a = path[i], b = path[i + 1];
    pos = LatLng(a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t);
    heading = bear[i];
  }
}
