import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

const kTileHost = 'https://tile.openstreetmap.org';
const kTileUa = 'FamilyBox/1.3 (personal family app)';
const int kMaxParallel = 4;

/// Сколько тайлов не удалось загрузить за всё время работы приложения.
int tileFailures = 0;

Directory? _root;
Future<Directory> tileRoot() async {
  if (_root != null) return _root!;
  final d = await getApplicationDocumentsDirectory();
  final t = Directory('${d.path}/osmtiles');
  if (!await t.exists()) await t.create(recursive: true);
  _root = t;
  return t;
}

final http.Client tileClient = http.Client();

int _active = 0;
final List<Completer<void>> _queue = [];

Future<void> _acquire() async {
  if (_active < kMaxParallel) {
    _active++;
    return;
  }
  final c = Completer<void>();
  _queue.add(c);
  await c.future;
  _active++;
}

void _release() {
  _active--;
  if (_active < 0) _active = 0;
  if (_queue.isNotEmpty) {
    final c = _queue.removeAt(0);
    if (!c.isCompleted) c.complete();
  }
}

Future<Uint8List?> fetchTile(int z, int x, int y) async {
  final root = await tileRoot();
  final f = File('${root.path}/$z/$x/$y.png');
  if (await f.exists()) {
    try {
      final b = await f.readAsBytes();
      if (b.isNotEmpty) return b;
    } catch (_) {}
  }
  await _acquire();
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final r = await tileClient.get(Uri.parse('$kTileHost/$z/$x/$y.png'),
            headers: {'User-Agent': kTileUa}).timeout(const Duration(seconds: 20));
        if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
          try {
            await f.parent.create(recursive: true);
            await f.writeAsBytes(r.bodyBytes);
          } catch (_) {}
          return r.bodyBytes;
        }
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: 300 + attempt * 500));
    }
  } finally {
    _release();
  }
  tileFailures++;
  return null;
}

Uint8List? _blank;
Future<Uint8List> blankPng() async {
  if (_blank != null) return _blank!;
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 256, 256),
      ui.Paint()..color = const ui.Color(0x00000000));
  final img = await rec.endRecording().toImage(256, 256);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  _blank = bd!.buffer.asUint8List();
  return _blank!;
}

class CachedTileProvider extends TileProvider {
  CachedTileProvider();
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _TileImage(coordinates.z.round(), coordinates.x.round(), coordinates.y.round());
}

class _TileImage extends ImageProvider<_TileImage> {
  _TileImage(this.z, this.x, this.y);
  final int z, x, y;

  @override
  Future<_TileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_TileImage>(this);

  @override
  ImageStreamCompleter loadImage(_TileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _codec(decode), scale: 1);

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async {
    var bytes = await fetchTile(z, x, y);
    bytes ??= await blankPng();
    final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buf);
  }

  @override
  bool operator ==(Object other) =>
      other is _TileImage && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);
}

int lonToTileX(double lon, int z) =>
    ((lon + 180.0) / 360.0 * (1 << z)).floor();

int latToTileY(double lat, int z) {
  final r = lat * math.pi / 180.0;
  final n = 1 << z;
  return ((1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0 * n).floor();
}

class AreaDownload {
  AreaDownload(this.sw, this.ne, this.zooms);
  final LatLng sw, ne;
  final List<int> zooms;

  List<List<int>> jobs() {
    final out = <List<int>>[];
    for (final z in zooms) {
      final x1 = lonToTileX(sw.longitude, z);
      final x2 = lonToTileX(ne.longitude, z);
      final y1 = latToTileY(ne.latitude, z);
      final y2 = latToTileY(sw.latitude, z);
      for (var x = x1; x <= x2; x++) {
        for (var y = y1; y <= y2; y++) {
          out.add([z, x, y]);
        }
      }
    }
    return out;
  }

  int total() => jobs().length;

  Future<void> run(void Function(int done, int total) progress,
      bool Function() cancel) async {
    final list = jobs();
    var idx = 0;
    var done = 0;
    Future<void> worker() async {
      while (true) {
        if (cancel()) return;
        final i = idx++;
        if (i >= list.length) return;
        final j = list[i];
        await fetchTile(j[0], j[1], j[2]);
        done++;
        progress(done, list.length);
      }
    }
    await Future.wait([worker(), worker(), worker()]);
  }
}

Future<int> cachedTileCount() async {
  final root = await tileRoot();
  var n = 0;
  if (!await root.exists()) return 0;
  await for (final e in root.list(recursive: true)) {
    if (e is File && e.path.endsWith('.png')) n++;
  }
  return n;
}
