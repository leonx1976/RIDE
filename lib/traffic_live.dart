import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'main.dart';

const _base = 'https://yandex.ru/maps/6/kaluga/transport/?l=sat%2Cskl';
const _startUrl = '$_base&ll=36.251580%2C54.517620&z=16';
const _fileName = 'адреса транспорта.txt';

const _sniffJs = r'''
(function(){
  if (window.__sniff) return;
  window.__sniff = true;
  var seen = {};
  function send(o){ try { Sniff.postMessage(JSON.stringify(o)); } catch(e){} }
  function skip(u){
    return /\.(js|css|png|jpg|jpeg|svg|woff2?|ttf|ico|gif|webp|mp4)(\?|$)/i.test(u)
      || /(metrika|mc\.yandex|top-fwz|adfox|an\.yandex|awaps|\/clck\/|favicon)/i.test(u);
  }
  function key(u){
    try { var x = new URL(u, location.href); return x.host + x.pathname; }
    catch(e){ return String(u).split('?')[0]; }
  }
  function note(kind, u, ct, n, s){
    if (!u || skip(u)) return;
    var k = kind + '|' + key(u);
    if (seen[k]) return;
    seen[k] = 1;
    send({k:kind, u:String(u).slice(0,600), ct:ct||'', n:n||0, s:(s||'').slice(0,500)});
  }
  var of = window.fetch;
  if (of) {
    window.fetch = function(input, init){
      var u = (typeof input === 'string') ? input : (input && input.url) || '';
      var p = of.apply(this, arguments);
      try {
        p.then(function(res){
          try {
            var ct = res.headers.get('content-type') || '';
            if (/json|text|protobuf|octet-stream/i.test(ct)) {
              res.clone().text().then(function(t){ note('fetch', u, ct, t.length, t); })
                .catch(function(){ note('fetch', u, ct, 0, ''); });
            } else { note('fetch', u, ct, 0, ''); }
          } catch(e){ note('fetch', u, '', 0, ''); }
        }).catch(function(){});
      } catch(e){}
      return p;
    };
  }
  var oo = XMLHttpRequest.prototype.open;
  var os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u){ this.__u = u; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(){
    var self = this;
    this.addEventListener('load', function(){
      try {
        var ct = self.getResponseHeader('content-type') || '';
        var s = '';
        if (self.responseType === '' || self.responseType === 'text') {
          s = self.responseText || '';
        } else if (self.responseType === 'arraybuffer' && self.response) {
          var b = new Uint8Array(self.response), h = '';
          for (var i=0;i<Math.min(48,b.length);i++) h += (b[i]<16?'0':'') + b[i].toString(16);
          s = 'HEX:' + h;
        }
        note('xhr', self.__u, ct, s.length, s);
      } catch(e){ note('xhr', self.__u, '', 0, ''); }
    });
    return os.apply(this, arguments);
  };
  var OW = window.WebSocket;
  if (OW) {
    var NW = function(u, p){
      note('ws', u, 'websocket', 0, '');
      var s = p ? new OW(u, p) : new OW(u);
      var c = 0;
      s.addEventListener('message', function(ev){
        if (c++ > 2) return;
        if (typeof ev.data === 'string') note('ws-msg', u, 'text', ev.data.length, ev.data);
        else note('ws-msg', u, 'binary', 0, '');
      });
      return s;
    };
    NW.prototype = OW.prototype;
    window.WebSocket = NW;
  }
  function sweep(){
    try {
      var es = performance.getEntriesByType('resource');
      for (var i=0;i<es.length;i++) {
        note('res', es[i].name, es[i].initiatorType, Math.round(es[i].transferSize||0), '');
      }
    } catch(e){}
  }
  sweep();
  setInterval(sweep, 3000);
})();
''';

const _hideJs = r'''
(function(){
  function hide(e){
    if (!e || e.getAttribute('data-fbh')) return;
    try { e.setAttribute('data-fbh','1'); e.style.setProperty('display','none','important'); } catch(x){}
  }
  function canvasIn(e){ try { return !!e.querySelector('canvas'); } catch(x){ return false; } }
  function small(e){ try { return e.offsetHeight > 0 && e.offsetHeight <= 240; } catch(x){ return false; } }
  var K = ['banner','advert','promo','install','smart','subscription','onboarding','cookie',
           'notice','popup','modal','disclaimer','story','share','social','header','footer',
           'sidebar','topbar','app-bar','rtb','adfox'];
  var T = /^(скачать|установить|продолжить в приложении|открыть в приложении|открыть приложение|подробнее|не сейчас|позже|закрыть)$/i;
  function run(){
    K.forEach(function(k){
      document.querySelectorAll('[class*="'+k+'"],[id*="'+k+'"]').forEach(function(e){
        if (!canvasIn(e) && small(e)) hide(e);
      });
    });
    document.querySelectorAll('iframe').forEach(function(e){
      var s = e.getAttribute('src') || '';
      if (/ads|adfox|an\.yandex|doubleclick|rtb/i.test(s)) hide(e);
    });
    document.querySelectorAll('a,button,[role="button"]').forEach(function(e){
      var t = (e.textContent || '').trim();
      if (t.length > 40 || !T.test(t)) return;
      var p = e;
      for (var i=0;i<5 && p;i++){
        if (small(p) && !canvasIn(p)) { hide(p); break; }
        p = p.parentElement;
      }
    });
  }
  run();
  if (window.__fbH) return;
  var n = 0;
  window.__fbH = setInterval(function(){ n++; run(); if (n>=40){ clearInterval(window.__fbH); window.__fbH=null; } }, 600);
})();
''';

const _strictJs = r'''
(function(){
  function canvasIn(e){ try { return !!e.querySelector('canvas'); } catch(x){ return false; } }
  var K = ['zoom','control','toolbar','layers','traffic','ruler','compass','scale',
           'copyright','attrib','logo','search','menu','tabs','panel','btn','button'];
  K.forEach(function(k){
    document.querySelectorAll('[class*="'+k+'"]').forEach(function(e){
      try {
        if (canvasIn(e)) return;
        if (e.offsetHeight > 240 || e.offsetHeight <= 0) return;
        e.style.setProperty('display','none','important');
      } catch(x){}
    });
  });
})();
''';

class _Hit {
  _Hit(this.kind, this.url, this.ct, this.size, this.sample);
  final String kind, url, ct, sample;
  final int size;
}

class TrafficLivePage extends StatefulWidget {
  const TrafficLivePage({super.key});
  @override
  State<TrafficLivePage> createState() => _TrafficLivePageState();
}

class _TrafficLivePageState extends State<TrafficLivePage>
    with SingleTickerProviderStateMixin {
  late final WebViewController c;
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  final Map<String, _Hit> _hits = {};
  Timer? _autoSave;
  Timer? _pingTimer;
  bool _dirty = false;
  bool _ping = false;
  bool _pingPending = false;
  bool _strict = false;
  bool _locBusy = false;
  double _progress = 0;
  String _path = '';
  String _url = _startUrl;

  @override
  void initState() {
    super.initState();
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel('Sniff', onMessageReceived: (JavaScriptMessage m) {
        _accept(m.message);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (v) { if (mounted) setState(() => _progress = v / 100); },
        onPageStarted: (_) async {
          try { await c.runJavaScript(_sniffJs); } catch (_) {}
        },
        onPageFinished: (_) async {
          try { await c.runJavaScript(_sniffJs); } catch (_) {}
          try { await c.runJavaScript(_hideJs); } catch (_) {}
          if (_strict) { try { await c.runJavaScript(_strictJs); } catch (_) {} }
          if (_pingPending) {
            _pingPending = false;
            _showPing();
          }
        },
        onNavigationRequest: (r) => r.url.startsWith('http')
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ))
      ..loadRequest(Uri.parse(_startUrl));

    _autoSave = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_dirty) _save(quiet: true);
    });
  }

  @override
  void dispose() {
    _autoSave?.cancel();
    _pingTimer?.cancel();
    _pulse.dispose();
    if (_dirty) _save(quiet: true);
    super.dispose();
  }

  void _accept(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final url = (m['u'] as String?) ?? '';
      if (url.isEmpty) return;
      final kind = (m['k'] as String?) ?? '?';
      final key = '$kind|${url.split('?').first}';
      if (_hits.containsKey(key)) return;
      _hits[key] = _Hit(kind, url, (m['ct'] as String?) ?? '',
          (m['n'] as num?)?.toInt() ?? 0, (m['s'] as String?) ?? '');
      _dirty = true;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  int _score(_Hit h) {
    final u = h.url.toLowerCase();
    var s = 0;
    if (RegExp(r'masstransit|transport|vehicle|mov|trf|forecast').hasMatch(u)) s += 100;
    if (u.contains('/api/')) s += 60;
    if (RegExp(r'tile|protobuf|pbf').hasMatch(u)) s += 40;
    if (h.kind == 'ws' || h.kind == 'ws-msg') s += 80;
    if (h.sample.isNotEmpty) s += 30;
    if (RegExp(r'json|protobuf').hasMatch(h.ct.toLowerCase())) s += 20;
    return s;
  }

  String _report() {
    final list = _hits.values.toList()
      ..sort((a, b) => _score(b).compareTo(_score(a)));
    final b = StringBuffer();
    b.writeln('ОТЧЁТ: АДРЕСА ТРАНСПОРТА');
    b.writeln('Дата: ${DateTime.now()}');
    b.writeln('Страница: $_url');
    b.writeln('Записей: ${list.length}');
    b.writeln('==========================================');
    for (final h in list) {
      b.writeln('[${h.kind}] ${h.ct.isEmpty ? "-" : h.ct} ${h.size}B');
      b.writeln('URL: ${h.url}');
      if (h.sample.isNotEmpty) {
        b.writeln('SAMPLE: ${h.sample.replaceAll(RegExp(r'\s+'), ' ')}');
      }
      b.writeln('------------------------------------------');
    }
    return b.toString();
  }

  Future<void> _save({bool quiet = false}) async {
    final text = _report();
    String? ok;
    try {
      final d = Directory('/storage/emulated/0/Download');
      if (await d.exists()) {
        final f = File('${d.path}/$_fileName');
        await f.writeAsString(text, flush: true);
        ok = f.path;
      }
    } catch (_) {}
    if (ok == null) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          final f = File('${ext.path}/$_fileName');
          await f.writeAsString(text, flush: true);
          ok = f.path;
        }
      } catch (_) {}
    }
    if (ok == null) {
      try {
        final d = await getApplicationDocumentsDirectory();
        final f = File('${d.path}/$_fileName');
        await f.writeAsString(text, flush: true);
        ok = f.path;
      } catch (_) {}
    }
    _dirty = false;
    if (!mounted) return;
    setState(() => _path = ok ?? 'не удалось записать файл');
    if (!quiet) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok == null ? 'Файл не записан — используй «Скопировать»' : 'Сохранено: $ok'),
        duration: const Duration(seconds: 4),
      ));
    }
  }

  void _showPing() {
    setState(() => _ping = true);
    _pingTimer?.cancel();
    _pingTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _ping = false);
    });
  }

  Future<void> _locateMe() async {
    if (_locBusy) return;
    setState(() => _locBusy = true);
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
        _toast('Разреши геолокацию в настройках телефона', true);
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        _toast('Геолокация выключена', true);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      final url = '$_base&ll=${pos.longitude}%2C${pos.latitude}&z=17';
      _url = url;
      _pingPending = true;
      await c.loadRequest(Uri.parse(url));
    } catch (_) {
      _toast('Не удалось определить местоположение', true);
    } finally {
      if (mounted) setState(() => _locBusy = false);
    }
  }

  void _toast(String m, bool err) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: err ? context.c.error : null,
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _toggleStrict() async {
    final next = !_strict;
    setState(() => _strict = next);
    if (next) {
      try { await c.runJavaScript(_strictJs); } catch (_) {}
      _toast('Кнопки Яндекса скрыты. Если карта пропала — выключи.', false);
    } else {
      _toast('Перезагружаю карту с кнопками', false);
      await c.loadRequest(Uri.parse(_url));
    }
  }

  void _openLog() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final list = _hits.values.toList()
          ..sort((a, b) => _score(b).compareTo(_score(a)));
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.82,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(children: [
                Expanded(child: Text('Перехвачено: ${list.length}',
                    style: context.t.titleLarge)),
                IconButton(onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(child: FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _report()));
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                          content: Text('Отчёт скопирован — вставь его в чат')));
                    }
                  },
                  icon: const Icon(Icons.copy_all_rounded, size: 18),
                  label: const Text('Скопировать отчёт'),
                )),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () async { await _save(); setS(() {}); },
                  icon: const Icon(Icons.save_alt_rounded, size: 18),
                  label: const Text('Файл'),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(_path.isEmpty ? 'Файл ещё не записан' : _path,
                  style: context.t.bodySmall),
            ),
            const Divider(height: 12),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final h = list[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('[${h.kind}] ${h.ct} ${h.size}B', style: context.t.bodySmall),
                      SelectableText(h.url, style: context.t.bodyMedium),
                      if (h.sample.isNotEmpty)
                        SelectableText(h.sample, style: context.t.bodySmall),
                    ]),
                  );
                },
              ),
            ),
          ]),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      WebViewWidget(controller: c),
      if (_progress < 1)
        Positioned(top: 0, left: 0, right: 0,
            child: LinearProgressIndicator(value: _progress, minHeight: 2,
                color: context.c.primary)),
      if (_ping)
        Positioned.fill(child: IgnorePointer(child: Center(child: AnimatedBuilder(
          animation: _pulse,
          builder: (_, __) {
            final t = _pulse.value;
            return Stack(alignment: Alignment.center, children: [
              Container(
                width: 26 + 70 * t, height: 26 + 70 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: const Color(0xFFFF2D20).withOpacity(.6 * (1 - t)), width: 2.5),
                  color: const Color(0xFFFF2D20).withOpacity(.14 * (1 - t)),
                ),
              ),
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFF2D20),
                  border: Border.all(color: Colors.white, width: 3.5),
                  boxShadow: [BoxShadow(
                      color: const Color(0xFFFF2D20).withOpacity(.75), blurRadius: 16)],
                ),
              ),
            ]);
          },
        )))),
      Positioned(left: 10, right: 10, bottom: 10, child: _bar()),
    ]);
  }

  Widget _bar() => Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: context.c.surface.withOpacity(.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: context.c.outlineVariant),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(.2), blurRadius: 14)],
        ),
        child: Row(children: [
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF2D20),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
              ),
              onPressed: _locBusy ? null : _locateMe,
              icon: _locBusy
                  ? const SizedBox(width: 15, height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.my_location_rounded, size: 18),
              label: Text(_ping ? 'Я здесь' : 'Где я',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 8),
          _btn(Icons.refresh_rounded, 'Обновить', () => c.loadRequest(Uri.parse(_url))),
          const SizedBox(width: 6),
          _btn(_strict ? Icons.visibility_rounded : Icons.visibility_off_rounded,
              'Кнопки Яндекса', _toggleStrict,
              accent: _strict ? const Color(0xFFE08A2E) : null),
          const SizedBox(width: 6),
          _btn(Icons.receipt_long_rounded, 'Лог (${_hits.length})', _openLog,
              accent: const Color(0xFF2F80ED)),
        ]),
      );

  Widget _btn(IconData i, String tip, VoidCallback onTap, {Color? accent}) => Tooltip(
        message: tip,
        child: Material(
          color: accent?.withOpacity(.14) ?? Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          child: InkWell(
            borderRadius: BorderRadius.circular(13),
            onTap: onTap,
            child: Container(
              width: 48, height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: accent ?? context.c.outlineVariant, width: 1.2),
              ),
              child: Icon(i, size: 20, color: accent ?? context.c.primary),
            ),
          ),
        ),
      );
}