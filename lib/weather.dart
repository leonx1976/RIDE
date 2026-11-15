import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart';

const kKalugaLat = 54.5293;
const kKalugaLon = 36.2754;

class DayFx {
  const DayFx(this.date, this.code, this.tmax, this.tmin, this.pop);
  final DateTime date;
  final int code, pop;
  final double tmax, tmin;
}

class Weather {
  const Weather(this.temp, this.feels, this.wind, this.code, this.days, this.at, this.stale);
  final double temp, feels, wind;
  final int code;
  final List<DayFx> days;
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

String fmtT(double v) => '${v > 0 ? "+" : v < 0 ? "−" : ""}${v.abs().round()}°';
String two(int v) => v.toString().padLeft(2, '0');
const _wd = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

Future<Weather?> _fetchOpenMeteo() async {
  try {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '$kKalugaLat',
      'longitude': '$kKalugaLon',
      'current': 'temperature_2m,apparent_temperature,weather_code,wind_speed_10m',
      'daily': 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
      'timezone': 'Europe/Moscow',
      'forecast_days': '4',
    });
    final r = await http.get(uri, headers: {'User-Agent': 'FamilyBox/1.0'})
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final c = j['current'] as Map<String, dynamic>;
    final d = j['daily'] as Map<String, dynamic>;
    final days = <DayFx>[];
    final times = d['time'] as List;
    for (var i = 0; i < times.length && i < 4; i++) {
      days.add(DayFx(
        DateTime.parse(times[i] as String),
        (d['weather_code'][i] as num).toInt(),
        (d['temperature_2m_max'][i] as num).toDouble(),
        (d['temperature_2m_min'][i] as num).toDouble(),
        (d['precipitation_probability_max'][i] as num?)?.toInt() ?? 0,
      ));
    }
    return Weather(
      (c['temperature_2m'] as num).toDouble(),
      (c['apparent_temperature'] as num).toDouble(),
      (c['wind_speed_10m'] as num).toDouble(),
      (c['weather_code'] as num).toInt(),
      days, DateTime.now(), false,
    );
  } catch (_) {
    return null;
  }
}

Future<Weather?> _fetchMetNo() async {
  try {
    final uri = Uri.parse(
        'https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=$kKalugaLat&lon=$kKalugaLon');
    final r = await http.get(uri, headers: {
      'User-Agent': 'FamilyBox/1.0 https://github.com',
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final props = j['properties'] as Map<String, dynamic>;
    final timeseries = props['timeseries'] as List;
    if (timeseries.isEmpty) return null;

    final now = ((timeseries.first as Map<String, dynamic>)['data'] as Map<String, dynamic>)['instant'];
    final det = ((now as Map<String, dynamic>)['details'] as Map<String, dynamic>);
    final temp = (det['air_temperature'] as num?)?.toDouble() ?? 0.0;
    final wind = ((det['wind_speed'] as num?)?.toDouble() ?? 0.0) * 3.6;

    final days = <DayFx>[];
    final byDay = <String, List<Map<String, dynamic>>>{};
    for (final ts in timeseries) {
      final m = ts as Map<String, dynamic>;
      final t = m['time'] as String;
      final dayKey = t.substring(0, 10);
      byDay.putIfAbsent(dayKey, () => []).add(m);
    }
    var i = 0;
    for (final entry in byDay.entries) {
      if (i >= 4) break;
      double tmax = -1000, tmin = 1000;
      var pop = 0;
      for (final m in entry.value) {
        final d = (((m['data'] as Map<String, dynamic>)['instant'] as Map<String, dynamic>)['details']
            as Map<String, dynamic>);
        final t = (d['air_temperature'] as num?)?.toDouble();
        if (t != null) { if (t > tmax) tmax = t; if (t < tmin) tmin = t; }
        final p = d['probability_of_precipitation'] as num?;
        if (p != null && p.toInt() > pop) pop = p.toInt();
      }
      if (tmax > -1000) {
        days.add(DayFx(DateTime.parse(entry.key), 3, tmax, tmin, pop));
        i++;
      }
    }
    if (days.isEmpty) return null;
    return Weather(temp, temp - 2, wind, 3, days, DateTime.now(), false);
  } catch (_) {
    return null;
  }
}

Future<Weather> loadWeather({bool force = false}) async {
  final p = await SharedPreferences.getInstance();
  String? body = p.getString('wx');
  final ts = p.getInt('wx_ts') ?? 0;
  var at = DateTime.fromMillisecondsSinceEpoch(ts);
  var stale = true;
  final age = DateTime.now().millisecondsSinceEpoch - ts;

  if (force || body == null || age > 30 * 60 * 1000) {
    var w = await _fetchOpenMeteo();
    w ??= await _fetchMetNo();
    if (w != null) {
      body = jsonEncode({
        'temp': w.temp, 'feels': w.feels, 'wind': w.wind, 'code': w.code,
        'days': w.days.map((d) => {
          'date': d.date.toIso8601String(),
          'code': d.code, 'tmax': d.tmax, 'tmin': d.tmin, 'pop': d.pop,
        }).toList(),
      });
      at = DateTime.now();
      stale = false;
      await p.setString('wx', body);
      await p.setInt('wx_ts', at.millisecondsSinceEpoch);
    }
  } else {
    stale = false;
  }

  if (body == null) throw Exception('Нет сети и сохранённой погоды');
  final j = jsonDecode(body) as Map<String, dynamic>;
  final days = (j['days'] as List).map((e) {
    final m = e as Map<String, dynamic>;
    return DayFx(
      DateTime.parse(m['date'] as String),
      (m['code'] as num).toInt(),
      (m['tmax'] as num).toDouble(),
      (m['tmin'] as num).toDouble(),
      (m['pop'] as num?)?.toInt() ?? 0,
    );
  }).toList();
  return Weather(
    (j['temp'] as num).toDouble(),
    (j['feels'] as num).toDouble(),
    (j['wind'] as num).toDouble(),
    (j['code'] as num).toInt(),
    days, at, stale,
  );
}

class WeatherCard extends StatefulWidget {
  const WeatherCard({super.key});
  @override
  State<WeatherCard> createState() => _WeatherCardState();
}

class _WeatherCardState extends State<WeatherCard> {
  late Future<Weather> _f = loadWeather();

  void _reload() => setState(() => _f = loadWeather(force: true));

  BoxDecoration _dec(BuildContext context) => BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: context.c.outlineVariant),
      );

  @override
  Widget build(BuildContext context) => FutureBuilder<Weather>(
        future: _f,
        builder: (context, s) {
          if (s.connectionState != ConnectionState.done) {
            return Container(
              height: 150,
              alignment: Alignment.center,
              decoration: _dec(context),
              child: const SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          if (s.hasError) {
            return InkWell(
              onTap: _reload,
              borderRadius: BorderRadius.circular(18),
              child: Container(
                height: 72,
                alignment: Alignment.center,
                decoration: _dec(context),
                child: Text('Погода недоступна · нажмите, чтобы повторить',
                    style: context.t.bodySmall),
              ),
            );
          }
          final w = s.data!;
          final now = wmo(w.code);
          return InkWell(
            onTap: _reload,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: _dec(context),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(now.icon, size: 36, color: context.c.primary),
                  const SizedBox(width: 14),
                  Text(fmtT(w.temp),
                      style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w600,
                          color: context.c.onSurface)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Калуга · сейчас', style: context.t.bodySmall),
                      const SizedBox(height: 3),
                      Text('${now.text}, ощущается ${fmtT(w.feels)}',
                          style: context.t.bodyMedium),
                      Text('ветер ${w.wind.round()} км/ч', style: context.t.bodySmall),
                    ]),
                  ),
                ]),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1, color: context.c.outlineVariant),
                ),
                Row(children: [
                  for (var i = 0; i < w.days.length && i < 3; i++)
                    Expanded(
                      child: _day(context, w.days[i],
                          i == 0 ? 'Сегодня' : _wd[w.days[i].date.weekday - 1]),
                    ),
                ]),
                const SizedBox(height: 10),
                Text(
                  w.stale
                      ? 'сохранено ${two(w.at.hour)}:${two(w.at.minute)} · нет сети'
                      : 'обновлено ${two(w.at.hour)}:${two(w.at.minute)} · Open-Meteo',
                  style: context.t.bodySmall,
                ),
              ]),
            ),
          );
        },
      );

  Widget _day(BuildContext context, DayFx d, String label) {
    final f = wmo(d.code);
    return Column(children: [
      Text(label, style: context.t.bodySmall),
      const SizedBox(height: 6),
      Icon(f.icon, size: 22, color: context.c.primary),
      const SizedBox(height: 6),
      Text('${fmtT(d.tmax)} / ${fmtT(d.tmin)}',
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: context.c.onSurface)),
      const SizedBox(height: 2),
      Text(d.pop >= 20 ? '${d.pop}%' : '—', style: context.t.bodySmall),
    ]);
  }
}