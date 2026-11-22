import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:webview_flutter/webview_flutter.dart';

const feedUrl =
    'https://yandex.ru/maps/6/kaluga/transport/?l=map&ll=36.261341%2C54.513678&z=13';
const _hookJs = r'''
(function(){
  if (window.__feed) return; window.__feed = 1;
  try {
    Object.defineProperty(document, 'hidden', {get:function(){return false;}, configurable:true});
    Object.defineProperty(document, 'visibilityState', {get:function(){return 'visible';}, configurable:true});
    document.hasFocus = function(){ return true; };
    window.requestAnimationFrame = function(cb){ return setTimeout(function(){ cb(Date.now()); }, 16); };
    window.cancelAnimationFrame = function(id){ clearTimeout(id); };
  } catch(e){}
  function post(t){ try { Feed.postMessage(t); } catch(e){} }
  var RX = /getVehiclesInfoWithRegion/;
  var of = window.fetch;
  if (of) {
    window.fetch = function(i, init){
      var u = (typeof i === 'string') ? i : (i && i.url) || '';
      var p = of.apply(this, arguments);
      if (RX.test(u)) {
        try { p.then(function(r){ r.clone().text().then(post).catch(function(){}); }).catch(function(){}); } catch(e){}
      }
      return p;
    };
  }
  var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u){ this.__u = u; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(){
    var s = this;
    if (RX.test(s.__u || '')) {
      s.addEventListener('load', function(){ try { post(s.responseText); } catch(e){} });
    }
    return os.apply(this, arguments);
  };
  setInterval(function(){
    try { window.dispatchEvent(new Event('resize')); } catch(e){}
    try { document.dispatchEvent(new Event('visibilitychange')); } catch(e){}
  }, 8000);
})();
''';

const _ecoJs = r'''
(function(){
  if (window.__eco) return; window.__eco = 1;
  var B = /core-renderer-tiles|sat0\d\.maps\.yandex|avatars\.mds|\/an\/|rtbcount|metrika|\/style\?protocol/;
  var of = window.fetch;
  window.fetch = function(i, init){
    var u = (typeof i === 'string') ? i : (i && i.url) || '';
    if (B.test(u)) {
      return Promise.resolve(new Response('{"data":{}}',
        {status:200, headers:{'content-type':'application/json'}}));
    }
    return of.apply(this, arguments);
  };
})();
''';

Map? _m(dynamic v) => v is Map ? v : null;
List? _l(dynamic v) => v is List ? v : null;

int kindOfType(String t) {
  final s = t.toLowerCase();
  if (s.contains('trolley')) return 0;
  if (s.contains('tram')) return 1;
  if (s.contains('minibus') || s.contains('taxi') || s.contains('marsh')) return 2;
  return 3;
}

class YVehicle {
  YVehicle(this.id, this.route, this.kind, this.trail, this.headAtEnd);
  final String id, route;
  final int kind;
  final List<LatLng> trail;
  final bool headAtEnd;

  LatLng get pos => headAtEnd ? trail.last : trail.first;

  double? get heading {
    if (trail.length < 2) return null;
    final a = headAtEnd ? trail[trail.length - 2] : trail[1];
    final b = const Distance().bearing(a, pos);
    return (b + 360) % 360;
  }
}

List<YVehicle> parseYandexVehicles(String body, bool headAtEnd) {
  final out = <YVehicle>[];
  try {
    final data = _m(_m(jsonDecode(body))?['data']);
    if (data == null) return out;
    for (final key in ['vehicles', 'seoVehicles']) {
      for (final e in (_l(data[key]) ?? const [])) {
        final v = _m(e);
        if (v == null) continue;
        final tr = _m(_m(_m(v['properties'])?['VehicleMetaData'])?['Transport']);
        final pts = <LatLng>[];
        for (final f in (_l(v['features']) ?? const [])) {
          final cs = _l(_m(_m(f)?['geometry'])?['coordinates']) ?? const [];
          for (final c in cs) {
            final p = _l(c);
            if (p == null || p.length < 2) continue;
            final lon = (p[0] as num?)?.toDouble();
            final lat = (p[1] as num?)?.toDouble();
            if (lon != null && lat != null) pts.add(LatLng(lat, lon));
          }
        }
        if (pts.isEmpty) continue;
        final id = (tr?['id'] ?? '${pts.last.latitude},${pts.last.longitude}').toString();
        final route = (tr?['name'] ?? '?').toString();
        var type = (tr?['type'] ?? '').toString();
        if (type.isEmpty) {
          final ts = _l(tr?['Types']);
          type = (ts != null && ts.isNotEmpty) ? ts.first.toString() : 'bus';
        }
        out.add(YVehicle(id, route, kindOfType(type), pts, headAtEnd));
      }
    }
  } catch (_) {}
  return out;
}

class TrafficFeed extends ChangeNotifier {
  late final WebViewController c;
  Widget? _host;
  Timer? _watch;
  bool headAtEnd = true;
  bool economy = false;
  bool running = true;
  int polls = 0;
  DateTime? updated;
  String? error;
  List<YVehicle> vehicles = [];

  TrafficFeed() {
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Feed', onMessageReceived: (JavaScriptMessage m) {
        _accept(m.message);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) async {
          if (economy) { try { await c.runJavaScript(_ecoJs); } catch (_) {} }
          try { await c.runJavaScript(_hookJs); } catch (_) {}
        },
        onPageFinished: (_) async {
          if (economy) { try { await c.runJavaScript(_ecoJs); } catch (_) {} }
          try { await c.runJavaScript(_hookJs); } catch (_) {}
        },
        onNavigationRequest: (r) => r.url.startsWith('http')
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ))
      ..loadRequest(Uri.parse(feedUrl));

    _watch = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!running) return;
      final age = updated == null
          ? 999
          : DateTime.now().difference(updated!).inSeconds;
      if (age > 90) {
        error = 'Нет свежих данных — перезагружаю источник';
        notifyListeners();
        c.loadRequest(Uri.parse(feedUrl));
      }
    });
  }

  Widget get host {
    _host ??= WebViewWidget(controller: c);
    return _host!;
  }

  void _accept(String body) {
    final list = parseYandexVehicles(body, headAtEnd);
    polls++;
    if (list.isEmpty) {
      if (vehicles.isEmpty) error = 'Источник ответил, но машин на линии нет';
      notifyListeners();
      return;
    }
    vehicles = list;
    updated = DateTime.now();
    error = null;
    notifyListeners();
  }

  void setHeadAtEnd(bool v) {
    headAtEnd = v;
    vehicles = vehicles
        .map((e) => YVehicle(e.id, e.route, e.kind, e.trail, v))
        .toList();
    notifyListeners();
  }

  Future<void> setEconomy(bool v) async {
    economy = v;
    if (v) { try { await c.runJavaScript(_ecoJs); } catch (_) {} }
    await c.loadRequest(Uri.parse(feedUrl));
    notifyListeners();
  }

  Future<void> setRunning(bool v) async {
    running = v;
    if (v) {
      await c.loadRequest(Uri.parse(feedUrl));
    } else {
      try { await c.loadHtmlString('<html><body></body></html>'); } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> refreshNow() async {
    await c.loadRequest(Uri.parse(feedUrl));
    notifyListeners();
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }
}
