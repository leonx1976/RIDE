import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart';

const _rad = math.pi / 180.0;

class CompassService extends ChangeNotifier {
  CompassService._();
  static final instance = CompassService._();

  StreamSubscription<AccelerometerEvent>? _acc;
  StreamSubscription<MagnetometerEvent>? _mag;
  int _users = 0;

  double _ax = 0, _ay = 0, _az = 9.81;
  double _mx = 0, _my = 0, _mz = 0;
  bool _magSeen = false;
  bool _sensorFailed = false;

  double _s = 0, _c = 0;
  bool _primed = false;
  double? _heading;
  double? _gpsHeading;
  double _field = 0;
  double _quality = 0;
  int _lastNotify = 0;

  double biasX = 0, biasY = 0, biasZ = 0;
  double offset = 0;
  bool calibrated = false;
  int calibAt = 0;
  bool autoOrient = false;

  bool capturing = false;
  double _minX = 1e9, _maxX = -1e9;
  double _minY = 1e9, _maxY = -1e9;
  double _minZ = 1e9, _maxZ = -1e9;
  int samples = 0;

  double? get heading => _heading ?? _gpsHeading;
  bool get hasMagnetometer => _magSeen && !_sensorFailed;
  double get quality => _quality;
  double get field => _field;

  double get captureScore {
    if (!capturing && samples == 0) return 0;
    final sx = (_maxX - _minX).clamp(0.0, 200.0);
    final sy = (_maxY - _minY).clamp(0.0, 200.0);
    final sz = (_maxZ - _minZ).clamp(0.0, 200.0);
    final spread = (sx + sy + sz) / 3.0;
    final bySpread = (spread / 70.0).clamp(0.0, 1.0);
    final bySamples = (samples / 220.0).clamp(0.0, 1.0);
    return (bySpread * 0.7 + bySamples * 0.3).clamp(0.0, 1.0);
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      biasX = p.getDouble('cmp_bx') ?? 0;
      biasY = p.getDouble('cmp_by') ?? 0;
      biasZ = p.getDouble('cmp_bz') ?? 0;
      offset = p.getDouble('cmp_off') ?? 0;
      calibrated = p.getBool('cmp_ok') ?? false;
      calibAt = p.getInt('cmp_at') ?? 0;
      autoOrient = p.getBool('cmp_auto') ?? false;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('cmp_bx', biasX);
      await p.setDouble('cmp_by', biasY);
      await p.setDouble('cmp_bz', biasZ);
      await p.setDouble('cmp_off', offset);
      await p.setBool('cmp_ok', calibrated);
      await p.setInt('cmp_at', calibAt);
    } catch (_) {}
  }

  Future<void> setAutoOrient(bool v) async {
    autoOrient = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('cmp_auto', v);
    } catch (_) {}
  }

  void acquire() {
    _users++;
    if (_users > 1) return;
    _primed = false;
    try {
      _acc = accelerometerEvents.listen((e) {
        _ax = e.x; _ay = e.y; _az = e.z;
        _compute();
      }, onError: (_) { _sensorFailed = true; });
      _mag = magnetometerEvents.listen((e) {
        _magSeen = true;
        _mx = e.x; _my = e.y; _mz = e.z;
        if (capturing) {
          samples++;
          if (e.x < _minX) _minX = e.x;
          if (e.x > _maxX) _maxX = e.x;
          if (e.y < _minY) _minY = e.y;
          if (e.y > _maxY) _maxY = e.y;
          if (e.z < _minZ) _minZ = e.z;
          if (e.z > _maxZ) _maxZ = e.z;
        }
        _compute();
      }, onError: (_) { _sensorFailed = true; });
    } catch (_) {
      _sensorFailed = true;
    }
  }

  void release() {
    _users--;
    if (_users > 0) return;
    _users = 0;
    _acc?.cancel(); _acc = null;
    _mag?.cancel(); _mag = null;
  }

  void setGpsCourse(double? deg, double speed) {
    if (deg == null || deg < 0 || speed < 0.8) {
      _gpsHeading = null;
    } else {
      _gpsHeading = deg;
    }
    if (!hasMagnetometer) {
      _heading = null;
      _touch();
    }
  }

  void startCapture() {
    capturing = true;
    samples = 0;
    _minX = 1e9; _maxX = -1e9;
    _minY = 1e9; _maxY = -1e9;
    _minZ = 1e9; _maxZ = -1e9;
    notifyListeners();
  }

  Future<void> finishCapture() async {
    if (samples > 30 && _maxX > _minX && _maxY > _minY && _maxZ > _minZ) {
      biasX = (_minX + _maxX) / 2;
      biasY = (_minY + _maxY) / 2;
      biasZ = (_minZ + _maxZ) / 2;
      calibrated = true;
      calibAt = DateTime.now().millisecondsSinceEpoch;
      await _save();
    }
    capturing = false;
    _primed = false;
    notifyListeners();
  }

  void cancelCapture() {
    capturing = false;
    notifyListeners();
  }

  Future<void> setNorthHere() async {
    final h = heading;
    if (h == null) return;
    var raw = h - offset;
    var next = -raw;
    while (next > 180) next -= 360;
    while (next < -180) next += 360;
    offset = next;
    calibrated = true;
    calibAt = DateTime.now().millisecondsSinceEpoch;
    _primed = false;
    await _save();
    notifyListeners();
  }

  Future<void> setOffset(double v) async {
    offset = v;
    calibrated = true;
    calibAt = DateTime.now().millisecondsSinceEpoch;
    _primed = false;
    await _save();
    notifyListeners();
  }

  Future<void> resetCalibration() async {
    biasX = 0; biasY = 0; biasZ = 0;
    offset = 0;
    calibrated = false;
    calibAt = 0;
    _primed = false;
    await _save();
    notifyListeners();
  }

  void _touch() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotify < 80) return;
    _lastNotify = now;
    notifyListeners();
  }

  void _compute() {
    final aN = math.sqrt(_ax * _ax + _ay * _ay + _az * _az);
    if (aN < 1) return;
    final ux = _ax / aN, uy = _ay / aN, uz = _az / aN;

    final mx = _mx - biasX, my = _my - biasY, mz = _mz - biasZ;
    _field = math.sqrt(mx * mx + my * my + mz * mz);
    if (_field < 5) { _quality = 0; _touch(); return; }

    final dot = mx * ux + my * uy + mz * uz;
    var nx = mx - dot * ux, ny = my - dot * uy, nz = mz - dot * uz;
    final nN = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nN < 4) { _quality = 0.15; _touch(); return; }
    nx /= nN; ny /= nN; nz /= nN;

    final ex = ny * uz - nz * uy;
    final ey = nz * ux - nx * uz;
    final ez = nx * uy - ny * ux;

    final flat = uz.abs() >= 0.7071;
    final fx = 0.0, fy = flat ? 1.0 : 0.0, fz = flat ? 0.0 : -1.0;
    final fd = fx * ux + fy * uy + fz * uz;
    var hx = fx - fd * ux, hy = fy - fd * uy, hz = fz - fd * uz;
    final hN = math.sqrt(hx * hx + hy * hy + hz * hz);
    if (hN < 0.12) { _quality = 0.2; _touch(); return; }
    hx /= hN; hy /= hN; hz /= hN;

    final nc = hx * nx + hy * ny + hz * nz;
    final ec = hx * ex + hy * ey + hz * ez;
    var deg = math.atan2(ec, nc) / _rad + offset;
    deg %= 360;
    if (deg < 0) deg += 360;

    final s = math.sin(deg * _rad), c = math.cos(deg * _rad);
    if (!_primed) {
      _s = s; _c = c; _primed = true;
    } else {
      _s = _s * 0.80 + s * 0.20;
      _c = _c * 0.80 + c * 0.20;
    }
    var out = math.atan2(_s, _c) / _rad;
    if (out < 0) out += 360;
    _heading = out;

    final fieldOk = (1.0 - ((_field - 50).abs() / 60)).clamp(0.0, 1.0);
    final horizOk = (nN / _field).clamp(0.0, 1.0);
    _quality = (fieldOk * 0.55 + horizOk * 0.45).clamp(0.0, 1.0);
    _touch();
  }
}

class CompassRose extends StatelessWidget {
  const CompassRose({super.key, required this.rotation, this.active = false,
      this.size = 46, this.onTap});
  final double rotation;
  final bool active;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: active
                ? [const Color(0xFF2F80ED), const Color(0xFF1B4FA8)]
                : [c.surface, c.surface],
          ),
          border: Border.all(
              color: active ? const Color(0xFF7FB2FF) : c.outlineVariant, width: 1.4),
          boxShadow: [
            BoxShadow(
                color: active
                    ? const Color(0xFF2F80ED).withOpacity(.45)
                    : Colors.black.withOpacity(.16),
                blurRadius: active ? 14 : 6,
                offset: const Offset(0, 2)),
          ],
        ),
        child: CustomPaint(
          painter: _RosePainter(
            rotation: rotation,
            active: active,
            tick: active ? Colors.white.withOpacity(.75) : c.onSurfaceVariant,
            label: active ? Colors.white : c.onSurface,
          ),
        ),
      ),
    );
  }
}

class _RosePainter extends CustomPainter {
  _RosePainter({required this.rotation, required this.active,
      required this.tick, required this.label});
  final double rotation;
  final bool active;
  final Color tick, label;

  @override
  void paint(Canvas canvas, Size size) {
    final ctr = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    canvas.save();
    canvas.translate(ctr.dx, ctr.dy);
    canvas.rotate(rotation * _rad);

    final tp = Paint()
      ..color = tick
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var a = 0; a < 360; a += 30) {
      final big = a % 90 == 0;
      final len = big ? r * 0.20 : r * 0.11;
      final s = math.sin(a * _rad), co = math.cos(a * _rad);
      canvas.drawLine(Offset(s * (r - 3), -co * (r - 3)),
          Offset(s * (r - 3 - len), -co * (r - 3 - len)), tp);
    }

    final north = Path()
      ..moveTo(0, -r * 0.60)
      ..lineTo(r * 0.17, r * 0.06)
      ..lineTo(0, -r * 0.10)
      ..close();
    final south = Path()
      ..moveTo(0, r * 0.60)
      ..lineTo(-r * 0.17, -r * 0.06)
      ..lineTo(0, r * 0.10)
      ..close();
    canvas.drawPath(
        north,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFF5A4E), Color(0xFFD62828)],
          ).createShader(Rect.fromLTWH(-r, -r, r * 2, r * 2)));
    canvas.drawPath(
        south,
        Paint()..color = active ? Colors.white.withOpacity(.55) : tick.withOpacity(.55));
    canvas.drawCircle(Offset.zero, r * 0.09,
        Paint()..color = active ? Colors.white : label);

    void letter(String t, double ang) {
      final painter = TextPainter(
        text: TextSpan(
            text: t,
            style: TextStyle(
                fontSize: r * 0.30,
                fontWeight: FontWeight.w700,
                color: t == 'С' ? const Color(0xFFFF6B5E) : label)),
        textDirection: TextDirection.ltr,
      )..layout();
      final s = math.sin(ang * _rad), co = math.cos(ang * _rad);
      final pos = Offset(s * r * 0.74, -co * r * 0.74);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(-rotation * _rad);
      painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
      canvas.restore();
    }

    letter('С', 0);
    letter('В', 90);
    letter('Ю', 180);
    letter('З', 270);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RosePainter old) =>
      old.rotation != rotation || old.active != active || old.tick != tick;
}

class CompassCalibrationSheet extends StatefulWidget {
  const CompassCalibrationSheet({super.key});
  @override
  State<CompassCalibrationSheet> createState() => _CompassCalibrationSheetState();
}

class _CompassCalibrationSheetState extends State<CompassCalibrationSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  double _off = CompassService.instance.offset;

  @override
  void dispose() { _spin.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final svc = CompassService.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([svc, _spin]),
      builder: (context, _) {
        final score = svc.captureScore;
        final q = svc.quality;
        final h = svc.heading;
        return Padding(
          padding: EdgeInsets.fromLTRB(
              20, 18, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(colors: [
                    Color(0xFF2F80ED), Color(0xFF3FA85F)
                  ]),
                ),
                child: const Icon(Icons.explore_rounded, color: Colors.white, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('Калибровка компаса', style: context.t.titleLarge)),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 6),
            Text('Настройка общая: она применяется и в навигаторе, '
                'и в движении транспорта.', style: context.t.bodySmall),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: context.c.surface,
                border: Border.all(color: context.c.outlineVariant),
              ),
              child: Row(children: [
                SizedBox(
                  width: 62, height: 62,
                  child: Stack(alignment: Alignment.center, children: [
                    SizedBox(
                      width: 62, height: 62,
                      child: CircularProgressIndicator(
                        value: svc.capturing ? score : q,
                        strokeWidth: 6,
                        backgroundColor: context.c.outlineVariant,
                        valueColor: AlwaysStoppedAnimation(
                            svc.capturing ? const Color(0xFFE08A2E) : _qColor(q)),
                      ),
                    ),
                    Transform.rotate(
                      angle: svc.capturing ? _spin.value * 2 * math.pi : 0,
                      child: Icon(
                          svc.capturing ? Icons.all_inclusive_rounded : Icons.explore_rounded,
                          size: 26,
                          color: svc.capturing
                              ? const Color(0xFFE08A2E)
                              : context.c.primary),
                    ),
                  ]),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        svc.capturing
                            ? 'Поводи телефон восьмёркой'
                            : (svc.hasMagnetometer
                                ? 'Качество компаса'
                                : 'Магнитометр не отвечает'),
                        style: context.t.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                        svc.capturing
                            ? 'Вращай его в воздухе, наклоняя в разные стороны. '
                              'Прогресс: ${(score * 100).round()}%'
                            : (svc.hasMagnetometer
                                ? '${(q * 100).round()}% · поле ${svc.field.round()} мкТ · '
                                  'азимут ${h == null ? "—" : "${h.round()}°"}'
                                : 'Ориентация будет по курсу GPS в движении'),
                        style: context.t.bodySmall),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: svc.capturing
                    ? FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF3FA85F)),
                        onPressed: score > 0.5 || svc.samples > 220
                            ? () async { await svc.finishCapture(); }
                            : null,
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('Завершить'))
                    : FilledButton.icon(
                        onPressed: () { svc.startCapture(); },
                        icon: const Icon(Icons.all_inclusive_rounded),
                        label: const Text('Восьмёрка')),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                    onPressed: h == null ? null : () => svc.setNorthHere(),
                    icon: const Icon(Icons.north_rounded),
                    label: const Text('Здесь север')),
              ),
            ]),
            if (svc.capturing)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButton(
                    onPressed: svc.cancelCapture,
                    child: const Text('Отменить сбор')),
              ),
            const SizedBox(height: 10),
            Text('Точная поправка: ${_off.round()}°', style: context.t.bodySmall),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: const Color(0xFF2F80ED),
                inactiveTrackColor: context.c.outlineVariant,
                thumbColor: const Color(0xFFE08A2E),
                overlayColor: const Color(0xFFE08A2E).withOpacity(.18),
              ),
              child: Slider(
                value: _off.clamp(-180, 180),
                min: -180, max: 180, divisions: 360,
                label: '${_off.round()}°',
                onChanged: (v) => setState(() => _off = v),
                onChangeEnd: (v) => svc.setOffset(v),
              ),
            ),
            Row(children: [
              Icon(svc.calibrated ? Icons.verified_rounded : Icons.info_outline_rounded,
                  size: 16,
                  color: svc.calibrated ? const Color(0xFF3FA85F) : context.c.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    svc.calibrated
                        ? 'Калибровка сохранена и подхватывается движением транспорта'
                        : 'Калибровка ещё не выполнялась',
                    style: context.t.bodySmall),
              ),
              TextButton(
                  onPressed: () async {
                    await svc.resetCalibration();
                    if (mounted) setState(() => _off = 0);
                  },
                  child: const Text('Сбросить')),
            ]),
          ]),
        );
      },
    );
  }

  Color _qColor(double q) {
    if (q > 0.66) return const Color(0xFF3FA85F);
    if (q > 0.38) return const Color(0xFFE08A2E);
    return const Color(0xFFEB5757);
  }
}

Future<void> showCompassCalibration(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => const CompassCalibrationSheet(),
  );
}
