import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:shared_preferences/shared_preferences.dart';

class KalugaSource {
  const KalugaSource(this.id, this.title, this.subtitle);
  final int id;
  final String title, subtitle;
  String get url => 'https://www.kaluga.ru/transport/$id';
}

const kSources = <KalugaSource>[
  KalugaSource(67, 'Вокзал Калуга-1', 'Электрички: отправление и прибытие'),
  KalugaSource(68, 'Сергиев Скит (Калуга-2)', 'Электрички по станции'),
  KalugaSource(69, 'Автовокзал Калуга-1', 'Междугородные автобусы'),
  KalugaSource(70, 'Пригородные автобусы', 'Городские и пригородные маршруты'),
];

enum ParseMode { exact, generic, stale, failed }

class TimeCell {
  const TimeCell(this.label, this.value, this.old);
  final String label, value, old;
}

class SchRow {
  const SchRow(this.route, this.title, this.times, this.note);
  final String route, title, note;
  final List<TimeCell> times;
}

class Group {
  const Group(this.title, this.rows);
  final String title;
  final List<SchRow> rows;
}

class Section {
  const Section(this.title, this.groups);
  final String title;
  final List<Group> groups;
}

class Schedule {
  const Schedule(this.title, this.updated, this.sections, this.at, this.mode);
  final String title, updated;
  final List<Section> sections;
  final DateTime at;
  final ParseMode mode;
}

class Sel {
  const Sel({
    this.row = '.sch-item',
    this.header = 'sch-header',
    this.route = '.sch-route',
    this.title = '.sch-title',
    this.time = '.sch-time',
    this.label = '.sch-direction',
    this.note = '.sch-note',
    this.tabs = 'button[data-bs-target]',
    this.heading = 'h3.title-2',
    this.updated = '.subtitle-by-day',
    this.pageTitle = 'h2.title-1',
  });
  final String row, header, route, title, time, label, note, tabs, heading, updated, pageTitle;

  Sel merge(Map<String, dynamic> j) => Sel(
        row: j['row'] ?? row,
        header: j['header'] ?? header,
        route: j['route'] ?? route,
        title: j['title'] ?? title,
        time: j['time'] ?? time,
        label: j['label'] ?? label,
        note: j['note'] ?? note,
        tabs: j['tabs'] ?? tabs,
        heading: j['heading'] ?? heading,
        updated: j['updated'] ?? updated,
        pageTitle: j['pageTitle'] ?? pageTitle,
      );
}

const kConfigUrl = '';

Future<Sel> _selectors() async {
  if (kConfigUrl.isEmpty) return const Sel();
  final p = await SharedPreferences.getInstance();
  try {
    final r = await http.get(Uri.parse(kConfigUrl)).timeout(const Duration(seconds: 4));
    if (r.statusCode == 200) {
      await p.setString('sel_cfg', r.body);
      return const Sel().merge(jsonDecode(r.body) as Map<String, dynamic>);
    }
  } catch (_) {}
  final cached = p.getString('sel_cfg');
  if (cached != null) {
    try {
      return const Sel().merge(jsonDecode(cached) as Map<String, dynamic>);
    } catch (_) {}
  }
  return const Sel();
}

const _low =
    '\u0402\u0403\u201a\u0453\u201e\u2026\u2020\u2021\u20ac\u2030\u0409\u2039\u040a\u040c\u040b\u040f'
    '\u0452\u2018\u2019\u201c\u201d\u2022\u2013\u2014\ufffd\u2122\u0459\u203a\u045a\u045c\u045b\u045f'
    '\u00a0\u040e\u045e\u0408\u00a4\u0490\u00a6\u00a7\u0401\u00a9\u0404\u00ab\u00ac\u00ad\u00ae\u0407'
    '\u00b0\u00b1\u0406\u0456\u0491\u00b5\u00b6\u00b7\u0451\u2116\u0454\u00bb\u0458\u0405\u0455\u0457';

String decodeCp1251(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    if (b < 0x80) {
      sb.writeCharCode(b);
    } else if (b < 0xC0) {
      sb.write(_low[b - 0x80]);
    } else {
      sb.writeCharCode(0x0410 + (b - 0xC0));
    }
  }
  return sb.toString();
}

final _reTime = RegExp(r'\b([01]?\d|2[0-3]):[0-5]\d\b');
final _reBare = RegExp(r'^\d{1,2}:[0-5]\d');
final _reNum = RegExp(r'^\d{1,5}[A-Za-zА-Яа-я]?(?:/\d{1,5})*(?:\s+экспресс)?$');
final _reDays = RegExp(
    r'^(ежедневно.*|по будням|по выходным|будние дни|выходные дни|кроме .*|пн[,. ].*|пт[,. ].*|по пятницам.*)$',
    caseSensitive: false);
final _reWs = RegExp(r'\s+');
final _reH = RegExp(r'^h[1-6]$');

String _norm(String s) => s.replaceAll('\u00a0', ' ').replaceAll(_reWs, ' ').trim();

String _nodeText(dom.Node n) {
  if (n is dom.Text) return n.data;
  if (n is dom.Element) {
    if (n.localName == 'br') return ' ';
    if (n.localName == 'script' || n.localName == 'style') return '';
    return n.nodes.map(_nodeText).join();
  }
  return '';
}

String _txt(dom.Element? e) => e == null ? '' : _norm(_nodeText(e));

List<String> _pieces(dom.Element el) {
  final out = <String>[];
  void walk(dom.Node n) {
    if (n is dom.Text) {
      final s = _norm(n.data);
      if (s.isNotEmpty) out.add(s);
    } else if (n is dom.Element) {
      for (final c in n.nodes) { walk(c); }
    }
  }
  for (final c in el.nodes) { walk(c); }
  return out;
}

bool _related(dom.Element a, dom.Element b) {
  if (identical(a, b)) return true;
  for (dom.Node? p = a.parentNode; p != null; p = p.parentNode) {
    if (identical(p, b)) return true;
  }
  for (dom.Node? p = b.parentNode; p != null; p = p.parentNode) {
    if (identical(p, a)) return true;
  }
  return false;
}

SchRow? _rowExact(dom.Element el, Sel s) {
  final route = _txt(el.querySelector(s.route));
  final title = _txt(el.querySelector(s.title));
  final note = _txt(el.querySelector(s.note));
  final labelClass = s.label.startsWith('.') ? s.label.substring(1) : '';
  final times = <TimeCell>[];
  var label = '';
  for (final c in el.querySelectorAll('${s.label}, ${s.time}')) {
    if (labelClass.isNotEmpty && c.classes.contains(labelClass)) {
      label = _txt(c).replaceAll(':', '');
      continue;
    }
    final full = _txt(c);
    final oldEl = c.querySelector('s, del, strike');
    var value = full, old = '';
    if (oldEl != null) {
      old = _txt(oldEl);
      value = _norm(full.replaceAll(old, ''));
    }
    if (value.isNotEmpty) times.add(TimeCell(label, value, old));
    label = '';
  }
  if (route.isEmpty && title.isEmpty && times.isEmpty) return null;
  return SchRow(route, title, times, note);
}

List<Group> _groupsExact(dom.Element scope, Sel s) {
  final out = <Group>[];
  var title = '';
  var rows = <SchRow>[];
  for (final el in scope.querySelectorAll('${s.heading}, ${s.row}')) {
    if (_reH.hasMatch(el.localName ?? '')) {
      if (rows.isNotEmpty) out.add(Group(title, rows));
      title = _txt(el);
      rows = <SchRow>[];
    } else if (!el.classes.contains(s.header)) {
      final r = _rowExact(el, s);
      if (r != null) rows.add(r);
    }
  }
  if (rows.isNotEmpty) out.add(Group(title, rows));
  return out;
}

List<Section> _parseExact(dom.Document doc, Sel s) {
  final out = <Section>[];
  final tabs = doc.querySelectorAll(s.tabs);
  if (tabs.isNotEmpty) {
    for (final b in tabs) {
      final id = (b.attributes['data-bs-target'] ?? '').replaceFirst('#', '');
      final pane = doc.getElementById(id);
      if (pane == null || pane.querySelector('iframe') != null) continue;
      final g = _groupsExact(pane, s);
      if (g.isNotEmpty) out.add(Section(_txt(b), g));
    }
  } else {
    final body = doc.body;
    if (body != null) {
      final g = _groupsExact(body, s);
      if (g.isNotEmpty) out.add(Section('', g));
    }
  }
  return out;
}

class _Ctx {
  final _t = <dom.Element, String>{};
  final _p = <dom.Element, List<String>>{};
  String t(dom.Element e) => _t.putIfAbsent(e, () => _norm(_nodeText(e)));
  List<String> p(dom.Element e) => _p.putIfAbsent(e, () => _pieces(e));
}

bool _isRecord(dom.Element el, _Ctx ctx) {
  final ps = ctx.p(el);
  if (ps.isEmpty) return false;
  if (!_reTime.hasMatch(ps.join(' '))) return false;
  if (!ps.any((p) => !_reTime.hasMatch(p) && p.length > 1)) return false;
  return ps.any((p) => _reBare.hasMatch(p) || p.endsWith(':'));
}

String _nearestHeading(dom.Element el) {
  dom.Node? cur = el;
  while (cur != null) {
    final parent = cur.parentNode;
    if (parent == null) break;
    final sibs = parent.nodes;
    final i = sibs.indexOf(cur);
    for (var j = i - 1; j >= 0; j--) {
      final s = sibs[j];
      if (s is dom.Element) {
        if (_reH.hasMatch(s.localName ?? '')) return _txt(s);
        final h = s.querySelector('h1,h2,h3,h4');
        if (h != null) return _txt(h);
      }
    }
    cur = parent;
  }
  return '';
}

SchRow _rowGeneric(dom.Element r) {
  final ps = _pieces(r);
  final route = ps.firstWhere((p) => _reNum.hasMatch(p), orElse: () => '');
  final note = ps.firstWhere((p) => _reDays.hasMatch(p), orElse: () => '');
  var title = '';
  for (final d in r.querySelectorAll('*')) {
    final tx = _txt(d);
    if (tx.isEmpty || _reTime.hasMatch(tx) || tx.endsWith(':')) continue;
    if (tx == route || (note.isNotEmpty && tx.startsWith(note))) continue;
    if (tx.length > title.length) title = tx;
  }
  final times = <TimeCell>[];
  var lab = '';
  for (final p in ps) {
    if (p.endsWith(':')) { lab = p.substring(0, p.length - 1); continue; }
    if (_reTime.hasMatch(p)) { times.add(TimeCell(lab, p, '')); lab = ''; }
  }
  return SchRow(route, title, times, note);
}

String _guessTitle(List<SchRow> rows, String heading) {
  if (heading.toLowerCase().contains('изменени')) return heading;
  final l = rows.take(3).expand((r) => r.times.map((t) => t.label.toLowerCase())).join(' ');
  if (l.contains('отправления из')) return 'Отправление';
  if (l.contains('прибытия в')) return 'Прибытие';
  return heading.isEmpty ? 'Расписание' : heading;
}

List<Section> _parseGeneric(dom.Document doc) {
  for (final e in doc.querySelectorAll('script,style,nav,header,footer,aside,iframe')) {
    e.remove();
  }
  final ctx = _Ctx();
  final cands = <MapEntry<dom.Element, List<dom.Element>>>[];
  for (final el in doc.querySelectorAll('*')) {
    final kids = el.children;
    if (kids.length < 2) continue;
    final rows = kids.where((k) => _isRecord(k, ctx)).toList();
    if (rows.length >= 2 && rows.length / kids.length >= 0.5) {
      cands.add(MapEntry(el, rows));
    }
  }
  cands.sort((a, b) => b.value.length.compareTo(a.value.length));

  final claimed = <dom.Element>[];
  final out = <Section>[];
  for (final c in cands) {
    final clash = claimed.any((k) => _related(c.key, k) || c.value.any((r) => _related(r, k)));
    if (clash) continue;
    claimed.addAll(c.value);
    final rows = c.value.map(_rowGeneric).where((r) => r.times.isNotEmpty).toList();
    if (rows.length < 2) continue;
    out.add(Section(_guessTitle(rows, _nearestHeading(c.key)), [Group('', rows)]));
  }
  return out;
}

bool _sane(List<Section> s) {
  final rows = s.expand((e) => e.groups).expand((g) => g.rows).toList();
  if (rows.length < 3) return false;
  final t = rows.where((r) => r.times.isNotEmpty).length;
  return t >= 3 && t / rows.length > 0.6;
}

Future<Schedule> loadSchedule(KalugaSource src, {bool force = false}) async {
  final p = await SharedPreferences.getInstance();
  final sel = await _selectors();
  final k = 'kaluga_${src.id}';
  var text = p.getString(k);
  final ts = p.getInt('${k}_ts') ?? 0;
  var at = DateTime.fromMillisecondsSinceEpoch(ts);
  var mode = ParseMode.stale;

  final expired = DateTime.now().millisecondsSinceEpoch - ts > 6 * 3600 * 1000;
  if (force || text == null || expired) {
    try {
      final r = await http.get(Uri.parse(src.url),
          headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) {
        text = decodeCp1251(r.bodyBytes);
        at = DateTime.now();
        await p.setString(k, text);
        await p.setInt('${k}_ts', at.millisecondsSinceEpoch);
      }
    } catch (_) {
      if (text == null) rethrow;
    }
  }

  var sections = <Section>[];
  var title = src.title;
  var updated = '';

  if (text != null) {
    final doc = html_parser.parse(text);
    final h = _txt(doc.querySelector(sel.pageTitle));
    if (h.isNotEmpty) title = h;
    updated = _txt(doc.querySelector(sel.updated));

    sections = _parseExact(doc, sel);
    mode = ParseMode.exact;

    if (!_sane(sections)) {
      sections = _parseGeneric(html_parser.parse(text));
      mode = ParseMode.generic;
    }

    if (_sane(sections)) {
      await p.setString('${k}_good', text);
      await p.setInt('${k}_good_ts', at.millisecondsSinceEpoch);
    } else {
      final good = p.getString('${k}_good');
      if (good != null) {
        final gd = html_parser.parse(good);
        sections = _parseExact(gd, sel);
        if (!_sane(sections)) sections = _parseGeneric(gd);
        at = DateTime.fromMillisecondsSinceEpoch(p.getInt('${k}_good_ts') ?? ts);
        mode = ParseMode.stale;
      } else {
        sections = [];
        mode = ParseMode.failed;
      }
    }
  }
  return Schedule(title, updated, sections, at, mode);
}
