import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'home_page.dart';
import 'main.dart';

class WebArgs {
  WebArgs(this.url, this.title,
      {this.clean = false,
      this.waitReady = false,
      this.bare = false,
      this.bannerOnly = false,
      this.geoOnly = false});
  final String url, title;
  final bool clean;
  final bool waitReady;
  final bool bare;
  final bool bannerOnly;
  final bool geoOnly;
}

String _mapJs(bool geoOnly) => '''
(function(){
  var GEO_ONLY = ${geoOnly ? 'true' : 'false'};
  var geoRe = /geolocat|geo-loc|locate|my-?location|my-?position|where-?i|найти меня|мо[её] местоположение|где я|определить местоположение/i;
  var otherRe = /zoom|layers?|traffic|ruler|panorama|compass|scale|search|menu|close|share|route|settings|filter|tabs|bookmark|feedback/i;
  function attr(e){
    return [e.getAttribute('class'), e.getAttribute('id'), e.getAttribute('aria-label'),
            e.getAttribute('title'), e.getAttribute('data-name'),
            (e.textContent || '').slice(0, 40)].join(' ');
  }
  function hide(e){
    if (!e || e.getAttribute('data-fbh')) return;
    try { e.setAttribute('data-fbh','1'); e.style.setProperty('display','none','important'); } catch(x){}
  }
  function keep(e){ try { e.setAttribute('data-fbk','1'); } catch(x){} }
  function hasCanvas(e){ try { return !!e.querySelector('canvas'); } catch(x){ return false; } }
  function small(e){ try { return e.offsetHeight > 0 && e.offsetHeight <= 240; } catch(x){ return false; } }
  function area(e){ try { return e.offsetWidth * e.offsetHeight; } catch(x){ return 0; } }
  function findMap(){
    var sels = ['[class*="map-container"]','[class*="map-view"]','[class*="map__"]',
                '[class*="ymaps"]','[id*="map"]','[class*="map"]'];
    var need = window.innerWidth * window.innerHeight * 0.30;
    for (var i=0;i<sels.length;i++){
      var l = document.querySelectorAll(sels[i]);
      for (var j=0;j<l.length;j++){ if (area(l[j]) >= need) return l[j]; }
    }
    var cs = document.querySelectorAll('canvas'), best = null, ba = 0;
    for (var k=0;k<cs.length;k++){ var a = area(cs[k]); if (a > ba){ ba = a; best = cs[k]; } }
    if (best && ba >= need) return best.parentElement || best;
    return document.body;
  }
  function findGeo(m){
    var l = m.querySelectorAll('button,[role="button"],a,[class*="geolocat"],[class*="locate"],[aria-label],[title]');
    for (var i=0;i<l.length;i++){ if (geoRe.test(attr(l[i]))) return l[i]; }
    return null;
  }
  var CHROME = ['banner','advert','promo','install','smart','subscription','onboarding',
                'cookie','notice','popup','modal','disclaimer','story','share','social',
                'header','footer','sidebar','topbar','app-bar','rtb','adfox','adv'];
  var CTRL = ['zoom','control','toolbar','layers','traffic','ruler','compass','scale',
              'copyright','attrib','logo','search','menu','tabs','panel','btn','button',
              'hint','tooltip','legend'];
  var TXT = /^(скачать|установить|продолжить в приложении|открыть в приложении|открыть приложение|подробнее|не сейчас|позже|закрыть)\$/i;
  function run(){
    var m = findMap();
    var g = findGeo(m);
    if (g){
      var p = g;
      while (p && p !== document.body){ keep(p); if (p === m) break; p = p.parentElement; }
    }
    CHROME.forEach(function(k){
      document.querySelectorAll('[class*="' + k + '"],[id*="' + k + '"]').forEach(function(e){
        if (e === g || (g && e.contains(g))) return;
        if (e.getAttribute('data-fbk')) return;
        if (!hasCanvas(e) && small(e)) hide(e);
      });
    });
    document.querySelectorAll('iframe').forEach(function(e){
      var s = (e.getAttribute('src') || '');
      if (/ads|adfox|an\\.yandex|doubleclick|rtb/i.test(s)) hide(e);
    });
    document.querySelectorAll('a,button,[role="button"]').forEach(function(e){
      var t = (e.textContent || '').trim();
      if (t.length > 40 || !TXT.test(t)) return;
      var p = e;
      for (var i=0;i<5 && p;i++){
        if (small(p) && !hasCanvas(p) && p !== g && !(g && p.contains(g))){ hide(p); break; }
        p = p.parentElement;
      }
    });
    if (!GEO_ONLY) return;
    CTRL.forEach(function(k){
      m.querySelectorAll('[class*="' + k + '"]').forEach(function(e){
        if (e === m || e === g) return;
        if (g && (e.contains(g) || g.contains(e))) return;
        if (e.getAttribute('data-fbk')) return;
        if (hasCanvas(e) || !small(e)) return;
        hide(e);
      });
    });
    m.querySelectorAll('button,[role="button"],a').forEach(function(e){
      if (e === g) return;
      if (g && (e.contains(g) || g.contains(e))) return;
      if (e.getAttribute('data-fbk')) return;
      if (hasCanvas(e) || !small(e)) return;
      if (!g && !otherRe.test(attr(e))) return;
      hide(e);
    });
  }
  run();
  if (window.__fbT) return;
  var n = 0, last = 0;
  window.__fbT = setInterval(function(){
    n++; run();
    if (n >= 30){ clearInterval(window.__fbT); window.__fbT = null; }
  }, 600);
  try {
    new MutationObserver(function(){
      var t = Date.now();
      if (t - last < 500) return;
      last = t; run();
    }).observe(document.body, {childList: true});
  } catch(x){}
})();
''';

class WebPage extends StatefulWidget {
  const WebPage({super.key, required this.args});
  final WebArgs args;
  @override
  State<WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<WebPage> {
  late final WebViewController c;
  double p = 0;
  bool _overlay = false;
  int _ticks = 0;
  Timer? _poll;
  Timer? _guard;

  static const _detectJs = r'''
(function(){
  var pay = document.getElementById('tk-pay');
  if (pay && pay.querySelector('form, input, button, iframe')) return 'ready';
  var inp = document.querySelector('form input[type="text"], form input[type="tel"], form input[type="number"], input[name*="card" i], input[placeholder*="карт" i]');
  if (inp) return 'ready';
  var ifr = document.querySelector('iframe[src*="pay"], iframe[src*="widget"], iframe[src*="t-karta"]');
  if (ifr) return 'ready';
  var btn = document.querySelectorAll('button, input[type="submit"]');
  for (var i=0;i<btn.length;i++){
    var t = (btn[i].textContent || btn[i].value || '').toLowerCase();
    if (t.indexOf('проверить') >= 0 || t.indexOf('пополнить') >= 0) return 'ready';
  }
  return 'wait';
})()
''';

  static const _earlyJs = r'''
(function(){
  if (document.getElementById('fb-hide')) return 'ok';
  var s = document.createElement('style');
  s.id = 'fb-hide';
  s.textContent = 'header,footer,nav,.navbar,.menu,.breadcrumb,.cookie-banner,.loader-wrapper,aside{display:none!important}';
  (document.head || document.documentElement).appendChild(s);
  return 'ok';
})()
''';

  static const _cleanJs = r'''
(function(){
  function pick(){
    var pay = document.getElementById('tk-pay');
    if (pay && pay.querySelector('form, input, button, iframe')) return pay;
    var inp = document.querySelector('form input[type="text"], form input[type="tel"], form input[type="number"], input[name*="card" i], input[placeholder*="карт" i]');
    if (inp) return inp.closest('form') || inp.parentElement || inp;
    var ifr = document.querySelector('iframe[src*="pay"], iframe[src*="widget"], iframe[src*="t-karta"]');
    if (ifr) return ifr;
    var btn = document.querySelectorAll('button, input[type="submit"]');
    for (var i=0;i<btn.length;i++){
      var t = (btn[i].textContent || btn[i].value || '').toLowerCase();
      if (t.indexOf('проверить') >= 0 || t.indexOf('пополнить') >= 0) {
        return btn[i].closest('form') || btn[i].parentElement || btn[i];
      }
    }
    return null;
  }
  var m = pick();
  var b = document.getElementById('cookieAcceptBtn');
  if (b) b.click();
  document.querySelectorAll('[class*="cookie"]').forEach(function(e){
    if (!m || !e.contains(m)) e.style.setProperty('display','none','important');
  });
  ['header','footer','nav','.navbar','.menu','.breadcrumb','.loader-wrapper','aside','h1','h5']
    .forEach(function(s){
      document.querySelectorAll(s).forEach(function(e){
        if (!m || !e.contains(m)) e.remove();
      });
    });
  if (!m) return 'noclean';
  var node = m;
  while (node && node !== document.body) {
    var par = node.parentElement;
    if (par) {
      for (var i=0;i<par.children.length;i++){
        var sib = par.children[i];
        if (sib !== node && !sib.contains(m)) sib.style.setProperty('display','none','important');
      }
    }
    node = par;
  }
  return 'cleaned';
})()
''';

  @override
  void initState() {
    super.initState();
    _overlay = widget.args.waitReady;
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (v) { if (mounted) setState(() => p = v / 100); },
        onPageStarted: (_) async {
          WebNav.instance.refresh();
          if (widget.args.clean) {
            try { await c.runJavaScript(_earlyJs); } catch (_) {}
          }
        },
        onPageFinished: (_) async {
          if (widget.args.bannerOnly || widget.args.geoOnly) {
            try { await c.runJavaScript(_mapJs(widget.args.geoOnly)); } catch (_) {}
          }
          if (widget.args.clean) {
            try { await c.runJavaScript(_earlyJs); } catch (_) {}
          }
          WebNav.instance.refresh();
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? false) _finish();
        },
        onNavigationRequest: (req) async {
          final u = req.url;
          if (u.startsWith('http://') || u.startsWith('https://')) {
            return NavigationDecision.navigate;
          }
          try {
            await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
          } catch (_) {}
          return NavigationDecision.prevent;
        },
      ))
      ..loadRequest(Uri.parse(widget.args.url));
    WebNav.instance.attach(c);
    _startWatch();
  }

  void _startWatch() {
    _poll?.cancel();
    _guard?.cancel();
    _ticks = 0;
    if (!widget.args.waitReady) return;
    if (mounted) setState(() => _overlay = true);
    if (widget.args.clean) {
      _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    }
    _guard = Timer(const Duration(seconds: 60), _finish);
  }

  void _stopWatch() {
    _poll?.cancel();
    _poll = null;
    _guard?.cancel();
    _guard = null;
  }

  void _finish() {
    _stopWatch();
    if (!mounted) return;
    setState(() => _overlay = false);
  }

  Future<void> _tick() async {
    if (!mounted || !_overlay) return;
    _ticks++;
    try {
      final r = await c.runJavaScriptReturningResult(_detectJs);
      final s = r.toString().replaceAll('"', '').trim().toLowerCase();
      if (s == 'ready') {
        _poll?.cancel();
        _poll = null;
        try { await c.runJavaScript(_cleanJs); } catch (_) {}
        await Future.delayed(const Duration(seconds: 2));
        _finish();
        return;
      }
    } catch (_) {}
    if (_ticks >= 110) _finish();
  }

  Future<void> _reload() async {
    _startWatch();
    await c.loadRequest(Uri.parse(widget.args.url));
  }

  @override
  void dispose() {
    _stopWatch();
    WebNav.instance.detach(c);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.args.bare) {
      return Stack(children: [
        WebViewWidget(controller: c),
        if (_overlay) _cover(context),
      ]);
    }
    return Stack(children: [
      Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
          child: Row(children: [
            Expanded(child: Text(widget.args.title, style: context.t.titleMedium,
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            IconButton(tooltip: 'Обновить', onPressed: _reload,
                icon: const Icon(Icons.refresh_rounded)),
            IconButton(tooltip: 'Открыть в браузере',
                onPressed: () => launchUrl(Uri.parse(widget.args.url),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_browser_rounded)),
          ]),
        ),
        if (p < 1) LinearProgressIndicator(value: p, minHeight: 2, color: context.c.primary),
        Expanded(child: WebViewWidget(controller: c)),
      ]),
      if (_overlay) _cover(context),
    ]);
  }

  Widget _cover(BuildContext context) => Positioned.fill(
        child: Container(
          color: context.c.surface,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 16),
              Text('Подключение', style: context.t.bodySmall),
            ]),
          ),
        ),
      );
}

class TkCard {
  TkCard(this.name, this.number);
  String name;
  final String number;
}

class CardPage extends StatefulWidget {
  const CardPage({super.key});
  @override
  State<CardPage> createState() => _CardPageState();
}

class _CardPageState extends State<CardPage> {
  static const _url = 'https://t-karta40.ru/proverka-balansa-transportnoj-karty/';
  static const _key = 'tk_cards_v2';
  final _ctrl = TextEditingController();
  List<TkCard> _cards = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      var raw = p.getString(_key);
      if (raw == null) {
        final old = p.getStringList('tk_cards') ?? [];
        if (old.isNotEmpty) {
          raw = jsonEncode(old.map((s) {
            final parts = s.split('|');
            return {'name': parts.first,
                    'number': parts.length > 1 ? parts[1] : parts.first};
          }).toList());
          await p.setString(_key, raw);
        }
      }
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _cards = list.map((e) => TkCard(e['name'] as String, e['number'] as String)).toList();
      }
    } catch (_) {
      _cards = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      return await p.setString(_key,
          jsonEncode(_cards.map((e) => {'name': e.name, 'number': e.number}).toList()));
    } catch (_) {
      return false;
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? context.c.error : null,
      duration: const Duration(seconds: 2),
    ));
  }

  String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');

  Future<void> _remember(String number, {String? name}) async {
    final n = _digits(number);
    if (n.length < 6) return;
    final padded = n.padLeft(9, '0');
    final i = _cards.indexWhere((e) => e.number == padded);
    final label = (name ?? '').trim();
    if (i >= 0) {
      if (label.isNotEmpty) _cards[i].name = label;
    } else {
      _cards.add(TkCard(label.isEmpty ? 'Карта $padded' : label, padded));
    }
    if (mounted) setState(() {});
    final ok = await _persist();
    _snack(ok ? 'Сохранено: $padded' : 'Не удалось сохранить карту', error: !ok);
  }

  void _open(String number) {
    final n = _digits(number);
    if (n.length < 6) {
      _snack('Введите номер карты — минимум 6 цифр', error: true);
      return;
    }
    final padded = n.padLeft(9, '0');
    _remember(padded);
    Navigator.pushNamed(context, '/web',
        arguments: WebArgs('$_url?card=$padded', 'Карта $padded',
            clean: true, waitReady: true));
  }

  Future<void> _addDialog() async {
    final nameCtrl = TextEditingController();
    final numberCtrl = TextEditingController(text: _ctrl.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сохранить карту'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Чья карта')),
          const SizedBox(height: 12),
          TextField(controller: numberCtrl, keyboardType: TextInputType.number,
              maxLength: 9, decoration: const InputDecoration(labelText: 'Номер, 9 цифр')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'ok'), child: const Text('Сохранить')),
        ],
      ),
    );
    if (result != 'ok') return;
    if (_digits(numberCtrl.text).length < 6) {
      _snack('Номер слишком короткий', error: true);
      return;
    }
    await _remember(numberCtrl.text, name: nameCtrl.text);
    _ctrl.clear();
  }

  Future<void> _remove(TkCard card) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить карту?'),
        content: Text('${card.name}\n№ ${card.number}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'ok'), child: const Text('Удалить')),
        ],
      ),
    );
    if (result != 'ok' || !mounted) return;
    setState(() => _cards.removeWhere((e) => e.number == card.number));
    final saved = await _persist();
    _snack(saved ? 'Карта удалена' : 'Не удалось сохранить изменения', error: !saved);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        const PageHeader('Транспортная карта',
            'Номер запоминается сам · долгий тап по карте — удалить'),
        for (final card in _cards)
          Tile(
            icon: Icons.credit_card_rounded,
            title: card.name,
            subtitle: '№ ${card.number}',
            onTap: () => _open(card.number),
            onLongPress: () => _remove(card),
          ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: context.c.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: context.c.outlineVariant)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Другая карта', style: context.t.titleMedium),
            const SizedBox(height: 12),
            TextField(controller: _ctrl, keyboardType: TextInputType.number, maxLength: 9,
                decoration: const InputDecoration(
                    labelText: 'Номер транспортной карты',
                    helperText: '9 цифр на обратной стороне карты',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: FilledButton(onPressed: () => _open(_ctrl.text),
                  child: const Text('Проверить баланс'))),
              const SizedBox(width: 12),
              IconButton.outlined(tooltip: 'Сохранить с именем', onPressed: _addDialog,
                  icon: const Icon(Icons.bookmark_add_outlined)),
            ]),
          ]),
        ),
      ],
    );
  }
}
