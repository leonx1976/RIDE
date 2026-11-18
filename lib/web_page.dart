import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'home_page.dart';
import 'main.dart';

class WebArgs {
  WebArgs(this.url, this.title,
      {this.clean = false, this.waitReady = false, this.hideChrome = false});
  final String url, title;
  final bool clean;
  final bool waitReady;
  final bool hideChrome;
}

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

  @override
  void initState() {
    super.initState();
    _overlay = widget.args.waitReady;
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (v) { if (mounted) setState(() => p = v / 100); },
        onPageStarted: (_) => WebNav.instance.refresh(),
        onPageFinished: (_) async {
          if (widget.args.hideChrome) _hideChrome();
          if (widget.args.clean) _waitForm();
          WebNav.instance.refresh();
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
  }

  Future<void> _hideChrome() async {
    const js = '''
      (function(){
        var sels = ['header','footer','[class*="header"]','[class*="topbar"]',
          '[class*="search-panel"]','[class*="sidebar"]','[class*="side-panel"]',
          '[class*="banner"]','[class*="advert"]','[class*="promo"]',
          '[class*="subscription"]','[class*="onboarding"]','[class*="popup"]'];
        sels.forEach(function(s){
          document.querySelectorAll(s).forEach(function(e){
            if (!e.querySelector('canvas') && !e.querySelector('[class*="map"]')) {
              e.style.display='none';
            }
          });
        });
        document.body.style.overflow='hidden';
      })();
    ''';
    for (var i = 0; i < 6; i++) {
      try { await c.runJavaScript(js); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 700));
    }
  }

  Future<void> _waitForm({int attempt = 0}) async {
    if (!mounted) return;
    if (attempt > 64) {
      if (mounted) setState(() => _overlay = false);
      return;
    }
    try {
      final has = await c.runJavaScriptReturningResult('''
        (function(){
          var pay = document.getElementById('tk-pay');
          return !!(pay && pay.querySelector('form, input, button'));
        })()
      ''');
      if (has == true) {
        await c.runJavaScript('''
          var b = document.getElementById('cookieAcceptBtn');
          if (b) b.click();
          ['header','footer','.loader-wrapper','.cookie-banner','.breadcrumb',
           'nav','.navbar','.menu','aside','h1','h5'].forEach(function(s){
            document.querySelectorAll(s).forEach(function(e){ e.remove(); });
          });
          var pay = document.getElementById('tk-pay');
          if (pay) {
            var node = pay;
            while (node && node !== document.body) {
              var parent = node.parentElement;
              if (parent) {
                for (var i = 0; i < parent.children.length; i++) {
                  if (parent.children[i] !== node) parent.children[i].style.display='none';
                }
              }
              node = parent;
            }
          }
        ''');
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _overlay = false);
        return;
      }
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 500), () => _waitForm(attempt: attempt + 1));
  }

  @override
  void dispose() {
    WebNav.instance.detach(c);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
            child: Row(children: [
              Expanded(child: Text(widget.args.title, style: context.t.titleMedium,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              IconButton(tooltip: 'Обновить', onPressed: () => c.reload(),
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
        if (_overlay)
          Positioned.fill(child: Container(
            color: context.c.surface,
            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Подключение', style: context.t.bodySmall),
            ])),
          )),
      ]);
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
