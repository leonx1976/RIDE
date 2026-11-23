import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'routes_map.dart';

const _ua = 'FamilyBox/1.5 (personal family app)';
const _govUrls = [
  'https://www.kaluga-gov.ru/infrastruktura/obshchestvennyy-transport/raspisanie-dvizheniya/',
  'https://kaluga-gov.ru/infrastruktura/obshchestvennyy-transport/raspisanie-dvizheniya/',
];

String _clean(String s) => s
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&mdash;', '—')
    .replaceAll('&ndash;', '–')
    .replaceAll('&#8212;', '—')
    .replaceAll('&#8211;', '–')
    .replaceAll('&laquo;', '«')
    .replaceAll('&raquo;', '»')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _hasDash(String s) => RegExp(r'\s[—–-]\s').hasMatch(s);

bool _looksLikePlace(String s) => RegExp(
        r'(ул\.|улица|пос\.|поселок|посёлок|мкр|микрорайон|ст\.|станция|скв|сквер|дер\.|деревня|село|пр-т|проспект|площадь|пл\.|переулок|пер\.|шоссе|тракт|парк|бульвар)',
        caseSensitive: false)
    .hasMatch(s);

bool _junk(String s) => RegExp(
        r'(расписан|скачать|\.pdf|\.xls|\.doc|приказ|изменен|телефон|график работы)',
        caseSensitive: false)
    .hasMatch(s);

String _tidy(String s) {
  var t = s.replaceAll(RegExp(r'\s*[—–-]\s*'), ' — ');
  t = t.toLowerCase();
  t = t.replaceAll(RegExp(r'\.(?=[а-яa-z])'), '. ');
  t = t.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
  t = t
      .replaceAll(RegExp(r'\bУл\.'), 'ул.')
      .replaceAll(RegExp(r'\bПос\.'), 'пос.')
      .replaceAll(RegExp(r'\bМкр\.'), 'мкр.')
      .replaceAll(RegExp(r'\bСт\.'), 'ст.')
      .replaceAll(RegExp(r'\bД\.'), 'д.')
      .replaceAll(RegExp(r'\bСкв\.'), 'скв.');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

void _walk(dynamic node, String path, void Function(String, String) visit) {
  if (node is Map) {
    node.forEach((k, v) => _walk(v, '$path.${k.toString()}', visit));
  } else if (node is List) {
    for (final e in node) {
      _walk(e, path, visit);
    }
  } else if (node is String) {
    visit(path, node);
  }
}

String? harvestTitle(Map vehicle, String routeNumber) {
  final stops = <String>[];
  final heads = <String>[];
  _walk(vehicle, '', (path, value) {
    final s = _clean(value);
    if (s.length < 3 || s.length > 90) return;
    if (!RegExp(r'[А-Яа-яЁё]').hasMatch(s)) return;
    if (RegExp(r'^[\d\s.,+\-–—№]*$').hasMatch(s)) return;
    final p = path.toLowerCase();
    if (p.contains('headsign') ||
        p.contains('direction') ||
        p.endsWith('.title') ||
        p.endsWith('.description')) {
      if (!heads.contains(s)) heads.add(s);
      return;
    }
    if (p.contains('stop') && p.endsWith('.name')) {
      if (!stops.contains(s)) stops.add(s);
      return;
    }
    if (p.contains('thread') && p.endsWith('.name') && _hasDash(s)) {
      if (!heads.contains(s)) heads.add(s);
    }
  });
  if (stops.length >= 2) {
    return _tidy('${stops.first} — ${stops.last}');
  }
  for (final h in heads) {
    if (_hasDash(h)) return _tidy(h);
  }
  if (heads.isNotEmpty) return _tidy(heads.first);
  if (stops.length == 1) return _tidy('через ${stops.first}');
  return null;
}

class RouteNames {
  RouteNames._();
  static final instance = RouteNames._();

  final Map<String, String> _harvest = {};
  final Map<String, String> _gov = {};
  final Map<String, String> _dirs = {};
  final List<String> _queue = [];
  final Set<String> _queued = {};
  Map<String, String> _dict = {};
  Timer? _timer;
  bool ready = false;
  void Function()? onChanged;

  void _notify() {
    final cb = onChanged;
    if (cb != null) cb();
  }

  Future<File> _file() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/route_names.json');
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({
        'harvest': _harvest,
        'gov': _gov,
        'dirs': _dirs,
      }), flush: true);
    } catch (_) {}
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        void put(String key, Map<String, String> target) {
          final raw = m[key];
          if (raw is Map) {
            raw.forEach((k, v) {
              if (v is String && v.isNotEmpty) target[k.toString()] = v;
            });
          }
        }
        put('harvest', _harvest);
        put('gov', _gov);
        put('dirs', _dirs);
      }
    } catch (_) {}
    ready = true;
    _notify();
    _timer ??= Timer.periodic(const Duration(milliseconds: 1300), (_) => _next());
    await _loadDict();
    await _loadGov();
  }

  Future<void> _loadDict() async {
    try {
      _dict = await loadRouteDescriptions();
      _notify();
    } catch (_) {}
  }

  Future<void> _loadGov() async {
    for (final url in _govUrls) {
      try {
        final r = await http.get(Uri.parse(url), headers: {'User-Agent': _ua})
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) continue;
        final html = utf8.decode(r.bodyBytes, allowMalformed: true);
        var added = 0;
        for (final m in RegExp(r'<(?:tr|li|p)[^>]*>(.*?)</(?:tr|li|p)>',
                dotAll: true)
            .allMatches(html)) {
          final raw = _clean(m.group(1) ?? '');
          if (raw.length < 8 || raw.length > 220) continue;
          final nm = RegExp(r'(?:№\s*)?(\d{1,3}[а-яА-Яa-zA-Z]?)').firstMatch(raw);
          if (nm == null) continue;
          var rest = raw.substring(nm.end).trim();
          rest = rest.replaceFirst(RegExp(r'^[\s.№)\-–—:,]+'), '');
          rest = rest.split(RegExp(r'\s{2,}|\s\(')).first.trim();
          if (rest.length < 6 || rest.length > 140) continue;
          if (!_hasDash(rest) || !_looksLikePlace(rest) || _junk(rest)) continue;
          final num = nm.group(1)!;
          if (_gov.containsKey(num)) continue;
          _gov[num] = _tidy(rest);
          added++;
        }
        if (added > 0) {
          await _save();
          _notify();
          return;
        }
      } catch (_) {}
    }
  }

  void offerHarvest(String number, String? title) {
    if (title == null || title.isEmpty) return;
    final n = number.split('/').first.trim();
    if (n.isEmpty) return;
    if (_harvest[n] == title) return;
    _harvest[n] = title;
    _save();
    _notify();
  }

  bool _known(String n, int kind) {
    final tag = (kind == 0 || kind == 1) ? 't' : 'b';
    return _harvest.containsKey(n) ||
        _gov.containsKey(n) ||
        _dict.containsKey('$n|$tag') ||
        _dict.containsKey('$n|') ||
        _dict.containsKey(n);
  }

  void ensureDirection(String number, int kind, LatLng tip) {
    final n = number.split('/').first.trim();
    if (n.isEmpty) return;
    if (_known(n, kind) || _dirs.containsKey(n)) return;
    if (_queued.contains(n)) return;
    _queued.add(n);
    _queue.add('$n|${tip.latitude}|${tip.longitude}');
  }

  Future<void> _next() async {
    if (_queue.isEmpty) return;
    final job = _queue.removeAt(0);
    final parts = job.split('|');
    if (parts.length < 3) return;
    final n = parts[0];
    final lat = double.tryParse(parts[1]);
    final lon = double.tryParse(parts[2]);
    if (lat == null || lon == null) return;
    try {
      final uri = Uri.parse('https://nominatim.openstreetmap.org/reverse'
          '?format=json&lat=$lat&lon=$lon&zoom=17&addressdetails=1');
      final r = await http.get(uri, headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final a = (j['address'] as Map<String, dynamic>?) ?? {};
        final pick = (a['road'] ?? a['pedestrian'] ?? a['neighbourhood'] ??
            a['suburb'] ?? a['quarter'] ?? a['city_district'] ??
            a['village'] ?? a['town']) as String?;
        if (pick != null && pick.isNotEmpty) {
          _dirs[n] = _tidy(pick);
          await _save();
          _notify();
        }
      }
    } catch (_) {}
  }

  ({String title, String note}) resolve(String number, int kind) {
    final n = number.split('/').first.trim();
    final tag = (kind == 0 || kind == 1) ? 't' : 'b';
    final h = _harvest[n];
    if (h != null && h.isNotEmpty) {
      return (title: h, note: 'название от Яндекс.Транспорта');
    }
    final d = _dict['$n|$tag'] ?? _dict['$n|'] ?? _dict[n];
    if (d != null && d.isNotEmpty) {
      return (title: d, note: 'справочник АСОП');
    }
    final g = _gov[n];
    if (g != null && g.isNotEmpty) {
      return (title: g, note: 'список маршрутов города');
    }
    final dir = _dirs[n];
    if (dir != null && dir.isNotEmpty) {
      return (title: 'Направление: $dir', note: 'по геометрии маршрута');
    }
    return (title: 'Маршрут № $number', note: 'название уточняется…');
  }

  Future<void> refreshAll() async {
    await _loadDict();
    await _loadGov();
    _notify();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    onChanged = null;
  }
}