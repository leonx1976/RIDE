import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

const kTileHost = 'https://tile.openstreetmap.org';
const kTileUa = 'FamilyBox/1.1 (personal family app)';

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

Future<Uint8List?> fetchTile(int z, int x, int y) async {
  final root = await tileRoot();
  final f = File('${root.path}/$z/$x/$y.png');
  if (await f.exists()) {
    try {
      return await f.readAsBytes();
    } catch (_) {}
  }
  try {
    final r = await tileClient.get(Uri.parse('$kTileHost/$z/$x/$y.png'),
        headers: {'User-Agent': kTileUa}).timeout(const Duration(seconds: 15));
    if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
      try {
        await f.parent.create(recursive: true);
        await f.writeAsBytes(r.bodyBytes);
      } catch (_) {}
      return r.bodyBytes;
    }
  } catch (_) {}
  return null;
}

Uint8List? _blank;
Future<Uint8List> blankPng() async {
  if (_blank != null) return _blank!;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 256, 256),
      Paint()..color = const Color(0x00000000));
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
      SynchronousFuture(this);

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
    await Future.wait([worker(), worker(), worker(), worker()]);
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