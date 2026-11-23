import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'route_names.dart';

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
  }, 5000);
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
  YVehicle(this.id, this.route, this.kind, this.trail);
  final String id, route;
  final int kind;
  final List<LatLng> trail;
  LatLng get head => trail.first;
}

List<YVehicle> parseYandexVehicles(String body) {
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
        final id = (tr?['id'] ?? '${pts.first.latitude},${pts.first.longitude}').toString();
        final route = (tr?['name'] ?? '?').toString();
        var type = (tr?['type'] ?? '').toString();
        if (type.isEmpty) {
          final ts = _l(tr?['Types']);
          type = (ts != null && ts.isNotEmpty) ? ts.first.toString() : 'bus';
        }
        final kind = kindOfType(type);
        RouteNames.instance.offerHarvest(route, harvestTitle(v, route));
        RouteNames.instance.ensureDirection(route, kind, pts.last);
        out.add(YVehicle(id, route, kind, pts));
      }
    }
  } catch (_) {}
  return out;
}

class TrafficFeed extends ChangeNotifier {
  late final WebViewController c;
  Widget? _host;
  Timer? _watch;
  int polls = 0;
  DateTime? updated;
  String? error;
  List<YVehicle> vehicles = [];
  final Map<String, DateTime> seen = {};

  TrafficFeed() {
    RouteNames.instance.onChanged = () {
      if (!_closed) notifyListeners();
    };
    RouteNames.instance.load();

    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Feed', onMessageReceived: (JavaScriptMessage m) {
        _accept(m.message);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) async {
          try { await c.runJavaScript(_hookJs); } catch (_) {}
        },
        onPageFinished: (_) async {
          try { await c.runJavaScript(_hookJs); } catch (_) {}
        },
        onNavigationRequest: (r) => r.url.startsWith('http')
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ))
      ..loadRequest(Uri.parse(feedUrl));

    _watch = Timer.periodic(const Duration(seconds: 12), (_) {
      if (_closed) return;
      final age = updated == null ? 999 : DateTime.now().difference(updated!).inSeconds;
      if (age > 90) {
        error = 'Нет свежих данных — перезагружаю источник';
        notifyListeners();
        c.loadRequest(Uri.parse(feedUrl));
      }
    });
  }

  bool _closed = false;

  Widget get host {
    _host ??= WebViewWidget(controller: c);
    return _host!;
  }

  int ageOf(String id) {
    final t = seen[id];
    return t == null ? -1 : DateTime.now().difference(t).inSeconds;
  }

  ({String title, String note}) resolve(YVehicle v) =>
      RouteNames.instance.resolve(v.route, v.kind);

  String titleOf(YVehicle v) => resolve(v).title;

  void _accept(String body) {
    final list = parseYandexVehicles(body);
    polls++;
    final now = DateTime.now();
    if (list.isNotEmpty) {
      for (final v in list) {
        seen[v.id] = now;
        final i = vehicles.indexWhere((e) => e.id == v.id);
        if (i >= 0) {
          vehicles[i] = v;
        } else {
          vehicles.add(v);
        }
      }
      vehicles.removeWhere((e) {
        final t = seen[e.id];
        return t == null || now.difference(t).inSeconds > 90;
      });
      updated = now;
      error = null;
    } else if (vehicles.isEmpty) {
      error = 'Источник ответил, но машин на линии нет';
    }
    if (!_closed) notifyListeners();
  }

  Future<void> refreshNow() async {
    await RouteNames.instance.refreshAll();
    await c.loadRequest(Uri.parse(feedUrl));
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _watch?.cancel();
    RouteNames.instance.onChanged = null;
    super.dispose();
  }
}
