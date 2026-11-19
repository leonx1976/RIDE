import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart';

const _lat = 54.513678;
const _lon = 36.261341;
const _jsprav = 'https://pogoda.jsprav.ru/ru/kaluga/';
const _ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

const _monthsGen = ['января','февраля','марта','апреля','мая','июня',
                    'июля','августа','сентября','октября','ноября','декабря'];
const _monNum = {
  'января': 1, 'февраля': 2, 'марта': 3, 'апреля': 4, 'мая': 5, 'июня': 6,
  'июля': 7, 'августа': 8, 'сентября': 9, 'октября': 10, 'ноября': 11, 'декабря': 12,
};

class PartWx {
  const PartWx(this.name, this.code, this.temp, this.feels, this.wind,
      this.mm, this.pop, this.hum, this.desc);
  final String name, desc;
  final int code, pop, hum;
  final double temp, feels, wind, mm;
}

class DayWx {
  const DayWx(this.date, this.tmin, this.tmax, this.parts);
  final DateTime date;
  final double tmin, tmax;
  final List<PartWx> parts;
}

class Wx {
  const Wx(this.days, this.at, this.stale, this.source);
  final List<DayWx> days;
  final DateTime at;
  final bool stale;
  final String source;
}

({String text, IconData icon}) wmo(int c) {
  if (c == 0) return (text: 'Ясно', icon: Icons.wb_sunny_rounded);
  if (c <= 2) return (text: 'Малооблачно', icon: Icons.wb_cloudy_rounded);
  if (c == 3) return (text: 'Пасмурно', icon: Icons.cloud_rounded);
  if (c == 45 || c == 48) return (text: 'Туман', icon: Icons.blur_on_rounded);
  if (c >= 51 && c <= 57) return (text: 'Морось', icon: Icons.grain_rounded);
  if (c == 66 || c == 67 || c == 68 || c == 69) {
    return (text: 'Мокрый снег', icon: Icons.ac_unit_rounded);
  }
  if (c >= 61 && c <= 65) return (text: 'Дождь', icon: Icons.umbrella_rounded);
  if (c >= 71 && c <= 77) return (text: 'Снег', icon: Icons.ac_unit_rounded);
  if (c >= 80 && c <= 82) return (text: 'Ливень', icon: Icons.umbrella_rounded);
  if (c == 85 || c == 86) return (text: 'Снегопад', icon: Icons.ac_unit_rounded);
  if (c >= 95) return (text: 'Гроза', icon: Icons.flash_on_rounded);
  return (text: 'Облачно', icon: Icons.cloud_rounded);
}

int _codeFromDesc(String s) {
  final d = s.toLowerCase();
  if (d.contains('гроз')) return 95;
  if (d.contains('град')) return 96;
  if (d.contains('мокрый снег') || d.contains('дождь со снегом')) return 68;
  if (d.contains('снежн') || d.contains('снег')) {
    return d.contains('небольш') ? 71 : 73;
  }
  if (d.contains('ливен') || d.contains('ливнев')) return 80;
  if (d.contains('морось')) return 51;
  if (d.contains('дожд')) {
    if (d.contains('сильн')) return 65;
    if (d.contains('небольш') || d.contains('слаб')) return 61;
    return 63;
  }
  if (d.contains('туман') || d.contains('дымк')) return 45;
  if (d.contains('пасмурн')) return 3;
  if (d.contains('переменн') || d.contains('небольшая облач')) return 2;
  if (d.contains('малооблач') || d.contains('облач')) return 2;
  if (d.contains('ясно')) return 0;
  return 3;
}

int _severity(int c) {
  if (c >= 95) return 9;
  if (c >= 80) return 8;
  if (c >= 71 && c <= 77) return 7;
  if (c >= 61 && c <= 69) return 6;
  if (c >= 51 && c <= 57) return 5;
  if (c == 45 || c == 48) return 4;
  if (c == 3) return 3;
  if (c == 2) return 2;
  if (c == 1) return 1;
  return 0;
}

String fmtT(double v) => '${v > 0 ? "+" : v < 0 ? "−" : ""}${v.abs().round()}°';
String two(int v) => v.toString().padLeft(2, '0');

double _num(String s) => double.tryParse(s.replaceAll(',', '.')) ?? 0;

String _strip(String s) => s
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

DateTime? _parseHeader(String h, DateTime now) {
  final m = RegExp(r'(\d{1,2})\s+([А-Яа-яЁё]+)').firstMatch(h);
  if (m == null) return null;
  final day = int.tryParse(m.group(1)!);
  final mon = _monNum[m.group(2)!.toLowerCase()];
  if (day == null || mon == null) return null;
  var year = now.year;
  if (now.month == 12 && mon == 1) year++;
  if (now.month == 1 && mon == 12) year--;
  return DateTime(year, mon, day);
}

const _partOrder = ['Утро', 'День', 'Вечер', 'Ночь'];
const _partMap = {'Утром': 'Утро', 'Днём': 'День', 'Вечером': 'Вечер', 'Ночью': 'Ночь'};

Future<Wx?> _fetchJsprav(DateTime now) async {
  try {
    final r = await http.get(Uri.parse(_jsprav), headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return null;
    final html = utf8.decode(r.bodyBytes, allowMalformed: true);
    final arts = RegExp(r'<article class="weather-tables-item">(.*?)</article>',
        dotAll: true).allMatches(html);
    final all = <DayWx>[];
    for (final a in arts) {
      final block = a.group(1) ?? '';
      final hm = RegExp(r'id="city-week-day-\d+"[^>]*>(.*?)</h3>', dotAll: true)
          .firstMatch(block);
      final pm = RegExp(r'class="sr-only[^"]*"[^>]*>(.*?)</p>', dotAll: true)
          .firstMatch(block);
      if (hm == null || pm == null) continue;
      final date = _parseHeader(_strip(hm.group(1)!), now);
      if (date == null) continue;
      final text = _strip(pm.group(1)!);
      final found = <String, PartWx>{};
      for (final p in RegExp(
              r'(Ночью|Утром|Днём|Вечером):(.*?)(?=(?:Ночью|Утром|Днём|Вечером):|$)',
              dotAll: true)
          .allMatches(text)) {
        final raw = p.group(1)!;
        final body = p.group(2) ?? '';
        final name = _partMap[raw];
        if (name == null) continue;
        final t = RegExp(r'температура\s*([+-]?\d+)').firstMatch(body);
        final f = RegExp(r'ощущается как\s*([+-]?\d+)').firstMatch(body);
        final d = RegExp(r'ощущается как\s*[+-]?\d+°?,\s*([^,]+)').firstMatch(body);
        final mm = RegExp(r'количество осадков\s*(\d+(?:[.,]\d+)?)').firstMatch(body);
        final w = RegExp(r'ветер\s+\S+\s+(\d+(?:[.,]\d+)?)').firstMatch(body);
        final hu = RegExp(r'влажность\s*(\d+)').firstMatch(body);
        if (t == null) continue;
        final desc = d != null ? d.group(1)!.trim() : '';
        found[name] = PartWx(
          name,
          _codeFromDesc(desc),
          _num(t.group(1)!),
          f != null ? _num(f.group(1)!) : _num(t.group(1)!),
          w != null ? _num(w.group(1)!) : 0,
          mm != null ? _num(mm.group(1)!) : 0,
          -1,
          hu != null ? int.parse(hu.group(1)!) : -1,
          desc.isEmpty ? wmo(_codeFromDesc(desc)).text : desc,
        );
      }
      if (found.isEmpty) continue;
      final parts = <PartWx>[];
      for (final n in _partOrder) {
        if (found.containsKey(n)) parts.add(found[n]!);
      }
      if (parts.isEmpty) continue;
      var mn = parts.first.temp, mx = parts.first.temp;
      for (final p in parts) {
        if (p.temp < mn) mn = p.temp;
        if (p.temp > mx) mx = p.temp;
      }
      all.add(DayWx(date, mn, mx, parts));
    }
    if (all.isEmpty) return null;
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    DayWx? pick(DateTime d) {
      for (final x in all) {
        if (x.date.year == d.year && x.date.month == d.month && x.date.day == d.day) {
          return x;
        }
      }
      return null;
    }
    final t0 = pick(today) ?? all.first;
    final t1 = pick(tomorrow) ?? (all.length > 1 ? all[1] : null);
    final days = <DayWx>[t0];
    if (t1 != null && t1.date != t0.date) days.add(t1);
    return Wx(days, DateTime.now(), false, 'pogoda.jsprav.ru');
  } catch (_) {
    return null;
  }
}

Future<Wx?> _fetchOpenMeteo(DateTime now) async {
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
    final r = await http.get(uri, headers: {'User-Agent': 'FamilyBox/1.3'})
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
      final idx = byDay[dTimes[k]] ?? <int>[];
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
      for (final name in _partOrder) {
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
        parts.add(PartWx(name, best, t / list.length, f / list.length,
            w / list.length, -1, pop, -1, wmo(best).text));
      }
      days.add(DayWx(
        DateTime.parse(dTimes[k]),
        (d['temperature_2m_min'][k] as num).toDouble(),
        (d['temperature_2m_max'][k] as num).toDouble(),
        parts,
      ));
    }
    if (days.isEmpty) return null;
    return Wx(days, DateTime.now(), false, 'Open-Meteo');
  } catch (_) {
    return null;
  }
}

String _pack(Wx w) => jsonEncode({
      'source': w.source,
      'days': w.days.map((d) => {
            'date': d.date.toIso8601String(),
            'tmin': d.tmin,
            'tmax': d.tmax,
            'parts': d.parts.map((p) => {
                  'name': p.name, 'code': p.code, 'temp': p.temp, 'feels': p.feels,
                  'wind': p.wind, 'mm': p.mm, 'pop': p.pop, 'hum': p.hum,
                  'desc': p.desc,
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
        return PartWx(
          q['name'] as String,
          (q['code'] as num).toInt(),
          (q['temp'] as num).toDouble(),
          (q['feels'] as num).toDouble(),
          (q['wind'] as num).toDouble(),
          (q['mm'] as num).toDouble(),
          (q['pop'] as num).toInt(),
          (q['hum'] as num).toInt(),
          (q['desc'] as String?) ?? '',
        );
      }).toList(),
    );
  }).toList();
  return Wx(days, at, stale, (j['source'] as String?) ?? '');
}

Future<Wx> loadWx({bool force = false}) async {
  final p = await SharedPreferences.getInstance();
  var body = p.getString('wx3');
  final ts = p.getInt('wx3_ts') ?? 0;
  var at = DateTime.fromMillisecondsSinceEpoch(ts);
  var stale = true;
  final age = DateTime.now().millisecondsSinceEpoch - ts;
  if (force || body == null || age > 30 * 60 * 1000) {
    final now = DateTime.now();
    var w = await _fetchJsprav(now);
    w ??= await _fetchOpenMeteo(now);
    if (w != null) {
      body = _pack(w);
      at = w.at;
      stale = false;
      await p.setString('wx3', body);
      await p.setInt('wx3_ts', at.millisecondsSinceEpoch);
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

  String _label(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (d.year == today.year && d.month == today.month && d.day == today.day) {
      return 'Сегодня';
    }
    final tm = today.add(const Duration(days: 1));
    if (d.year == tm.year && d.month == tm.month && d.day == tm.day) return 'Завтра';
    return '${d.day} ${_monthsGen[d.month - 1]}';
  }

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
              for (final d in w.days) _dayCard(context, d),
              const SizedBox(height: 6),
              Text(
                w.stale
                    ? 'сохранено ${two(w.at.hour)}:${two(w.at.minute)} · нет сети'
                    : 'обновлено ${two(w.at.hour)}:${two(w.at.minute)} · ${w.source}',
                style: context.t.bodySmall,
              ),
            ],
          );
        },
      );

  Widget _dayCard(BuildContext context, DayWx d) => Container(
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
                Text(_label(d.date), style: context.t.titleMedium),
                const SizedBox(height: 2),
                Text('${d.date.day} ${_monthsGen[d.date.month - 1]}',
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
    final precip = p.mm >= 0
        ? (p.mm > 0 ? '${p.mm.toStringAsFixed(1)} мм' : '—')
        : (p.pop >= 10 ? '$p.pop%' : '—');
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
      const SizedBox(height: 4),
      Text(p.desc.isEmpty ? f.text : p.desc,
          style: context.t.bodySmall,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
      const SizedBox(height: 4),
      Text(precip, style: context.t.bodySmall),
      Text('${p.wind.round()} м/с', style: context.t.bodySmall),
      if (p.hum >= 0) Text('${p.hum}%', style: context.t.bodySmall),
    ]);
  }
}
