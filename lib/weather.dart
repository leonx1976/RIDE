import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart';

const _lat = 54.513678;
const _lon = 36.261341;
const _months = ['января','февраля','марта','апреля','мая','июня',
                 'июля','августа','сентября','октября','ноября','декабря'];

class PartWx {
  const PartWx(this.name, this.code, this.temp, this.feels, this.pop, this.wind);
  final String name;
  final int code, pop;
  final double temp, feels, wind;
}

class DayWx {
  const DayWx(this.date, this.tmin, this.tmax, this.parts);
  final DateTime date;
  final double tmin, tmax;
  final List<PartWx> parts;
}

class Wx {
  const Wx(this.days, this.at, this.stale);
  final List<DayWx> days;
  final DateTime at;
  final bool stale;
}

({String text, IconData icon}) wmo(int c) {
  if (c == 0) return (text: 'Ясно', icon: Icons.wb_sunny_rounded);
  if (c <= 2) return (text: 'Малооблачно', icon: Icons.wb_cloudy_rounded);
  if (c == 3) return (text: 'Пасмурно', icon: Icons.cloud_rounded);
  if (c == 45 || c == 48) return (text: 'Туман', icon: Icons.blur_on_rounded);
  if (c >= 51 && c <= 57) return (text: 'Морось', icon: Icons.grain_rounded);
  if (c >= 61 && c <= 67) return (text: 'Дождь', icon: Icons.umbrella_rounded);
  if (c >= 71 && c <= 77) return (text: 'Снег', icon: Icons.ac_unit_rounded);
  if (c >= 80 && c <= 82) return (text: 'Ливень', icon: Icons.umbrella_rounded);
  if (c == 85 || c == 86) return (text: 'Снегопад', icon: Icons.ac_unit_rounded);
  if (c >= 95) return (text: 'Гроза', icon: Icons.flash_on_rounded);
  return (text: 'Облачно', icon: Icons.cloud_rounded);
}

int _severity(int c) {
  if (c >= 95) return 9;
  if (c >= 85 && c <= 86) return 8;
  if (c >= 80 && c <= 82) return 8;
  if (c >= 71 && c <= 77) return 7;
  if (c >= 61 && c <= 67) return 6;
  if (c >= 51 && c <= 57) return 5;
  if (c == 45 || c == 48) return 4;
  if (c == 3) return 3;
  if (c == 2) return 2;
  if (c == 1) return 1;
  return 0;
}

String fmtT(double v) => '${v > 0 ? "+" : v < 0 ? "−" : ""}${v.abs().round()}°';
String two(int v) => v.toString().padLeft(2, '0');

Future<Wx?> _fetch() async {
  try {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '$_lat',
      'longitude': '$_lon',
      'hourly': 'temperature_2m,apparent_temperature,weather_code,'
          'precipitation_probability,wind_speed_10m',
      'daily': 'temperature_2m_max,temperature_2m_min',
      'timezone': 'Europe/Moscow',
      'wind_speed_unit': 'ms',
      'forecast_days': '3',
    });
    final r = await http.get(uri, headers: {'User-Agent': 'FamilyBox/1.2'})
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final h = j['hourly'] as Map<String, dynamic>;
    final times = (h['time'] as List).cast<String>();
    final temp = h['temperature_2m'] as List;
    final feels = h['apparent_temperature'] as List;
    final codes = h['weather_code'] as List;
    final pops = h['precipitation_probability'] as List;
    final winds = h['wind_speed_10m'] as List;

    final byDay = <String, List<int>>{};
    for (var i = 0; i < times.length; i++) {
      byDay.putIfAbsent(times[i].substring(0, 10), () => []).add(i);
    }
    final d = j['daily'] as Map<String, dynamic>;
    final dTimes = (d['time'] as List).cast<String>();
    final days = <DayWx>[];
    for (var k = 0; k < dTimes.length && k < 2; k++) {
      final key = dTimes[k];
      final idx = byDay[key] ?? <int>[];
      if (idx.isEmpty) continue;
      final buckets = <String, List<int>>{
        'Утро': [], 'День': [], 'Вечер': [], 'Ночь': [],
      };
      for (final i in idx) {
        final hour = int.parse(times[i].substring(11, 13));
        final name = hour < 6 ? 'Ночь' : hour < 12 ? 'Утро' : hour < 18 ? 'День' : 'Вечер';
        buckets[name]!.add(i);
      }
      final parts = <PartWx>[];
      for (final name in ['Утро', 'День', 'Вечер', 'Ночь']) {
        final list = buckets[name]!;
        if (list.isEmpty) continue;
        double t = 0, f = 0, w = 0;
        var pop = 0;
        final freq = <int, int>{};
        for (final i in list) {
          t += (temp[i] as num).toDouble();
          f += (feels[i] as num).toDouble();
          w += (winds[i] as num).toDouble();
          final p = (pops[i] as num?)?.toInt() ?? 0;
          if (p > pop) pop = p;
          final c = (codes[i] as num).toInt();
          freq[c] = (freq[c] ?? 0) + 1;
        }
        var best = 0, bestN = -1;
        freq.forEach((c, n) {
          if (n > bestN || (n == bestN && _severity(c) > _severity(best))) {
            best = c; bestN = n;
          }
        });
        parts.add(PartWx(name, best, t / list.length, f / list.length, pop, w / list.length));
      }
      days.add(DayWx(
        DateTime.parse(key),
        (d['temperature_2m_min'][k] as num).toDouble(),
        (d['temperature_2m_max'][k] as num).toDouble(),
        parts,
      ));
    }
    if (days.isEmpty) return null;
    return Wx(days, DateTime.now(), false);
  } catch (_) {
    return null;
  }
}

String _pack(Wx w) => jsonEncode({
      'days': w.days.map((d) => {
            'date': d.date.toIso8601String(),
            'tmin': d.tmin,
            'tmax': d.tmax,
            'parts': d.parts.map((p) => {
                  'name': p.name, 'code': p.code, 'temp': p.temp,
                  'feels': p.feels, 'pop': p.pop, 'wind': p.wind,
                }).toList(),
          }).toList(),
    });

Wx _unpack(String body, DateTime at, bool stale) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  final days = (j['days'] as List).map((e) {
    final m = e as Map<String, dynamic>;
    return DayWx(
      DateTime.parse(m['date'] as String),
      (m['tmin'] as num).toDouble(),
      (m['tmax'] as num).toDouble(),
      (m['parts'] as List).map((p) {
        final q = p as Map<String, dynamic>;
        return PartWx(q['name'] as String, (q['code'] as num).toInt(),
            (q['temp'] as num).toDouble(), (q['feels'] as num).toDouble(),
            (q['pop'] as num).toInt(), (q['wind'] as num).toDouble());
      }).toList(),
    );
  }).toList();
  return Wx(days, at, stale);
}

Future<Wx> loadWx({bool force = false}) async {
  final p = await SharedPreferences.getInstance();
  var body = p.getString('wx2');
  final ts = p.getInt('wx2_ts') ?? 0;
  var at = DateTime.fromMillisecondsSinceEpoch(ts);
  var stale = true;
  final age = DateTime.now().millisecondsSinceEpoch - ts;
  if (force || body == null || age > 30 * 60 * 1000) {
    final w = await _fetch();
    if (w != null) {
      body = _pack(w);
      at = w.at;
      stale = false;
      await p.setString('wx2', body);
      await p.setInt('wx2_ts', at.millisecondsSinceEpoch);
    }
  } else {
    stale = false;
  }
  if (body == null) throw Exception('no weather');
  return _unpack(body, at, stale);
}

class WeatherPage extends StatefulWidget {
  const WeatherPage({super.key});
  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  late Future<Wx> _f = loadWx();

  void _reload() => setState(() => _f = loadWx(force: true));

  @override
  Widget build(BuildContext context) => FutureBuilder<Wx>(
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
                  Icon(Icons.cloud_off_rounded, size: 40, color: context.c.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text('Погода недоступна', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _reload, child: const Text('Повторить')),
                ]),
              ),
            );
          }
          final w = s.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              Row(children: [
                Expanded(child: Text('Погода · Калуга', style: context.t.titleLarge)),
                IconButton(onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
              ]),
              const SizedBox(height: 8),
              for (var i = 0; i < w.days.length && i < 2; i++)
                _dayCard(context, w.days[i], i == 0 ? 'Сегодня' : 'Завтра'),
              const SizedBox(height: 6),
              Text(
                w.stale
                    ? 'сохранено ${two(w.at.hour)}:${two(w.at.minute)} · нет сети'
                    : 'обновлено ${two(w.at.hour)}:${two(w.at.minute)} · Open-Meteo',
                style: context.t.bodySmall,
              ),
            ],
          );
        },
      );

  Widget _dayCard(BuildContext context, DayWx d, String label) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: context.c.outlineVariant),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: context.t.titleMedium),
                const SizedBox(height: 2),
                Text('${d.date.day} ${_months[d.date.month - 1]}',
                    style: context.t.bodySmall),
              ]),
            ),
            Text('${fmtT(d.tmax)} / ${fmtT(d.tmin)}',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600,
                    color: context.c.onSurface)),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: context.c.outlineVariant),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final p in d.parts) Expanded(child: _part(context, p)),
          ]),
        ]),
      );

  Widget _part(BuildContext context, PartWx p) {
    final f = wmo(p.code);
    return Column(children: [
      Text(p.name, style: context.t.bodySmall),
      const SizedBox(height: 6),
      Icon(f.icon, size: 24, color: context.c.primary),
      const SizedBox(height: 6),
      Text(fmtT(p.temp),
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
              color: context.c.onSurface)),
      const SizedBox(height: 2),
      Text('ощущ. ${fmtT(p.feels)}',
          style: context.t.bodySmall, textAlign: TextAlign.center),
      const SizedBox(height: 2),
      Text(p.pop >= 10 ? '$p.pop%' : '—', style: context.t.bodySmall),
      const SizedBox(height: 2),
      Text('${p.wind.round()} м/с', style: context.t.bodySmall),
    ]);
  }
}
