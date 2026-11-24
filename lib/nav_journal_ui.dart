import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'main.dart';
import 'nav_journal.dart';

export 'nav_journal.dart';

class NavSideTools extends StatefulWidget {
  const NavSideTools({super.key, required this.myPosition,
      required this.mapCenter, this.onFocus});
  final LatLng? Function() myPosition;
  final LatLng Function() mapCenter;
  final void Function(LatLng)? onFocus;

  @override
  State<NavSideTools> createState() => _NavSideToolsState();
}

class _NavSideToolsState extends State<NavSideTools> {
  @override
  void initState() {
    super.initState();
    NavJournal.instance.load();
  }

  void _toast(String m, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: err ? context.c.error : jGreenDeep,
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _askMark() async {
    final j = NavJournal.instance;
    final gps = widget.myPosition();
    final nameCtrl = TextEditingController(text: j.nextMarkName);
    var useGps = gps != null;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final p = useGps && gps != null ? gps : widget.mapCenter();
        return AlertDialog(
          title: Row(children: [
            _badge('М', jRed),
            const SizedBox(width: 10),
            const Expanded(child: Text('Новая метка')),
          ]),
          content: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Название метки', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Моя позиция'),
                    icon: Icon(Icons.my_location_rounded, size: 16)),
                ButtonSegment(value: false, label: Text('Центр карты'),
                    icon: Icon(Icons.center_focus_strong_rounded, size: 16)),
              ],
              selected: {useGps},
              showSelectedIcon: false,
              onSelectionChanged: gps == null
                  ? null
                  : (s) => setS(() => useGps = s.first),
            ),
            const SizedBox(height: 10),
            Text('${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}',
                style: context.t.bodySmall),
            if (gps == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('GPS ещё не определился — метка встанет в центр карты.',
                    style: context.t.bodySmall),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Сохранить')),
          ],
        );
      }),
    );
    if (saved != true) return;
    final p = useGps && gps != null ? gps : widget.mapCenter();
    await j.addMark(nameCtrl.text, p);
    _toast('Метка «${nameCtrl.text.trim().isEmpty ? j.nextMarkName : nameCtrl.text.trim()}» сохранена');
  }

  Future<void> _askTrack() async {
    final j = NavJournal.instance;
    if (j.recording) {
      final t = await j.stopRecording();
      _toast(t == null
          ? 'Трек не сохранён — меньше двух точек'
          : 'Трек «${t.name}» сохранён: ${t.points.length} точек, ${fmtLen(t.meters)}',
          err: t == null);
      return;
    }
    final nameCtrl = TextEditingController(text: j.nextTrackName);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          _badge('Т', jRed),
          const SizedBox(width: 10),
          const Expanded(child: Text('Запись трека')),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'Название маршрута', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Text('Запись начнётся сразу после подтверждения и будет идти, '
              'пока ты двигаешься. Остановить — повторное нажатие кнопки Т.',
              style: context.t.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: jRed),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.fiber_manual_record_rounded, size: 16),
            label: const Text('Начать'),
          ),
        ],
      ),
    );
    if (go != true) return;
    j.startRecording(nameCtrl.text);
    final gps = widget.myPosition();
    if (gps != null) j.feed(gps);
    _toast('Запись трека включена');
  }

  void _openJournal() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _JournalSheet(onFocus: widget.onFocus),
    );
  }

  @override
  Widget build(BuildContext context) {
    final j = NavJournal.instance;
    return AnimatedBuilder(
      animation: j,
      builder: (context, _) {
        final pulse = (DateTime.now().millisecondsSinceEpoch % 1200) / 1200.0;
        return Column(children: [
          if (j.recording) ...[
            Container(
              width: 46,
              padding: const EdgeInsets.symmetric(vertical: 5),
              decoration: BoxDecoration(
                color: jRed,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(
                    color: jRed.withOpacity(.35 + .4 * (1 - pulse)),
                    blurRadius: 6 + 10 * (1 - pulse))],
              ),
              child: Column(children: [
                const Icon(Icons.fiber_manual_record_rounded,
                    size: 12, color: Colors.white),
                Text('${j.recPoints.length}',
                    style: const TextStyle(color: Colors.white,
                        fontSize: 11, fontWeight: FontWeight.w900, height: 1.2)),
              ]),
            ),
            const SizedBox(height: 8),
          ],
          _letter('М', jRed, 'Сохранить метку', _askMark, false, pulse),
          const SizedBox(height: 8),
          _letter('Т', jRed, j.recording ? 'Остановить и сохранить трек' : 'Записать трек',
              _askTrack, j.recording, pulse),
          const SizedBox(height: 8),
          _letter('С', jGreenDeep, 'Журнал меток и треков', _openJournal, false, pulse,
              badge: j.marks.where((e) => e.on).length +
                  j.tracks.where((e) => e.on).length),
        ]);
      },
    );
  }

  Widget _letter(String letter, Color color, String tip, VoidCallback onTap,
      bool active, double pulse, {int badge = 0}) {
    return Tooltip(
      message: tip,
      child: Material(
        color: active ? color : context.c.surface,
        shape: const CircleBorder(),
        elevation: active ? 6 : 2,
        shadowColor: active ? color : Colors.black54,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color, width: active ? 2.6 : 1.6),
              boxShadow: active
                  ? [BoxShadow(color: color.withOpacity(.4 * (1 - pulse)),
                      blurRadius: 4 + 12 * (1 - pulse))]
                  : null,
            ),
            child: Stack(alignment: Alignment.center, children: [
              Text(letter,
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                      color: active ? Colors.white : color)),
              if (badge > 0)
                Positioned(
                  right: 3, top: 3,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: jGreen,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: Colors.white, width: 1.2),
                    ),
                    child: Text('$badge',
                        style: const TextStyle(fontSize: 8.5,
                            fontWeight: FontWeight.w900, color: Colors.white)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

Widget _badge(String letter, Color color) => Container(
      width: 30, height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withOpacity(.14),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Text(letter,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: color)),
    );

class _JournalSheet extends StatefulWidget {
  const _JournalSheet({this.onFocus});
  final void Function(LatLng)? onFocus;
  @override
  State<_JournalSheet> createState() => _JournalSheetState();
}

class _JournalSheetState extends State<_JournalSheet> {
  int _filter = 0;
  final ScrollController _sc = ScrollController();

  @override
  void dispose() { _sc.dispose(); super.dispose(); }

  Future<bool> _confirm(String name, String kind) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить?'),
        content: Text('Вы действительно хотите удалить $kind «$name»? '
            'Действие необратимо.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: jRed),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.close_rounded, size: 16),
            label: const Text('Удалить'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _focus(LatLng p) {
    widget.onFocus?.call(p);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final j = NavJournal.instance;
    return AnimatedBuilder(
      animation: j,
      builder: (context, _) {
        final showMarks = _filter != 2;
        final showTracks = _filter != 1;
        final total = j.marks.length + j.tracks.length;
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.84,
          child: Column(children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                gradient: LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [Color(0xFF14532D), Color(0xFF166534), Color(0xFF1E7A46)]),
              ),
              child: Row(children: [
                _badge('С', Colors.white),
                const SizedBox(width: 10),
                Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Журнал',
                      style: TextStyle(color: Colors.white, fontSize: 19,
                          fontWeight: FontWeight.w800)),
                  Text('${j.marks.length} меток · ${j.tracks.length} треков',
                      style: TextStyle(color: Colors.white.withOpacity(.8),
                          fontSize: 11.5)),
                ])),
                IconButton(
                  tooltip: 'Выключить все',
                  onPressed: total == null ? null : () => j.setAll(false),
                  icon: const Icon(Icons.visibility_off_rounded,
                      color: Colors.white, size: 20),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: Row(children: [
                _chip(0, 'Все', Icons.layers_rounded),
                const SizedBox(width: 6),
                _chip(1, 'Метки', Icons.close_rounded),
                const SizedBox(width: 6),
                _chip(2, 'Треки', Icons.timeline_rounded),
                const Spacer(),
                TextButton(onPressed: () => j.setAll(true),
                    child: const Text('Включить все')),
              ]),
            ),
            Expanded(
              child: total == 0
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 62, height: 62,
                            decoration: BoxDecoration(shape: BoxShape.circle,
                              color: jGreen.withOpacity(.14),
                              border: Border.all(color: jGreen.withOpacity(.5), width: 1.5)),
                            child: const Icon(Icons.bookmark_border_rounded,
                                size: 28, color: jGreenDeep),
                          ),
                          const SizedBox(height: 12),
                          Text('Журнал пуст', style: context.t.titleMedium),
                          const SizedBox(height: 6),
                          Text('Кнопка М сохранит точку на карте, '
                              'кнопка Т запишет пройденный путь.',
                              textAlign: TextAlign.center, style: context.t.bodySmall),
                        ]),
                      ),
                    )
                  : ScrollbarTheme(
                      data: ScrollbarThemeData(
                        thumbColor: WidgetStateProperty.all(jGreen),
                        trackColor: WidgetStateProperty.all(context.c.outlineVariant),
                        thickness: WidgetStateProperty.all(5),
                        radius: const Radius.circular(5),
                        thumbVisibility: WidgetStateProperty.all(true),
                      ),
                      child: Scrollbar(
                        controller: _sc,
                        child: ListView(
                          controller: _sc,
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 22),
                          children: [
                            if (showMarks)
                              for (final m in j.marks) _markRow(m),
                            if (showTracks)
                              for (final t in j.tracks) _trackRow(t),
                          ],
                        ),
                      ),
                    ),
            ),
          ]),
        );
      },
    );
  }

  Widget _chip(int i, String t, IconData icon) {
    final on = _filter == i;
    return Material(
      color: on ? jGreenDeep : jGreen.withOpacity(.12),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => setState(() => _filter = i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: on ? jGreenDeep : jGreen.withOpacity(.45)),
          ),
          child: Row(children: [
            Icon(icon, size: 14, color: on ? Colors.white : jGreenDeep),
            const SizedBox(width: 5),
            Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: on ? Colors.white : context.c.onSurface)),
          ]),
        ),
      ),
    );
  }

  Widget _shell({required bool on, required Widget child}) => AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        opacity: on ? 1 : .58,
        child: Container(
          margin: const EdgeInsets.only(bottom: 9),
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            color: context.c.surface,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
                color: on ? jGreen.withOpacity(.6) : context.c.outlineVariant,
                width: on ? 1.5 : 1),
            boxShadow: on
                ? [BoxShadow(color: jGreen.withOpacity(.18), blurRadius: 10)]
                : null,
          ),
          child: child,
        ),
      );

  Widget _markRow(NavMark m) {
    final j = NavJournal.instance;
    return _shell(
      on: m.on,
      child: Row(children: [
        _badge('М', jRed),
        const SizedBox(width: 10),
        Expanded(
          child: InkWell(
            onTap: () => _focus(m.point),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.name, style: context.t.titleMedium,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(fmtStamp(m.at), style: context.t.bodySmall),
            ]),
          ),
        ),
        Switch(value: m.on, activeColor: jGreen,
            onChanged: (v) => j.toggleMark(m.id, v)),
        _del(() async {
          if (await _confirm(m.name, 'метку')) await j.removeMark(m.id);
        }),
      ]),
    );
  }

  Widget _trackRow(NavTrack t) {
    final j = NavJournal.instance;
    return _shell(
      on: t.on,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _badge('Т', jRed),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () => _focus(t.points.first),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.name, style: context.t.titleMedium,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('${fmtStamp(t.at)} · ${t.points.length} точек · ${fmtLen(t.meters)}',
                    style: context.t.bodySmall),
              ]),
            ),
          ),
          Switch(value: t.on, activeColor: jGreen,
              onChanged: (v) => j.toggleTrack(t.id, v)),
          _del(() async {
            if (await _confirm(t.name, 'трек')) await j.removeTrack(t.id);
          }),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _mode(!t.straight, Icons.timeline_rounded, 'Как пройден',
              () => j.setStraight(t.id, false)),
          const SizedBox(width: 6),
          _mode(t.straight, Icons.trending_flat_rounded, 'По прямой',
              () => j.setStraight(t.id, true)),
        ]),
      ]),
    );
  }

  Widget _mode(bool on, IconData icon, String t, VoidCallback onTap) => Expanded(
        child: Material(
          color: on ? jGreenDeep : context.c.surface,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                    color: on ? jGreenDeep : context.c.outlineVariant),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 15, color: on ? Colors.white : jGreenDeep),
                const SizedBox(width: 5),
                Text(t, style: TextStyle(fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: on ? Colors.white : context.c.onSurface)),
              ]),
            ),
          ),
        ),
      );

  Widget _del(VoidCallback onTap) => Tooltip(
        message: 'Удалить',
        child: Material(
          color: jRed.withOpacity(.12),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: 34, height: 34,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  border: Border.all(color: jRed.withOpacity(.6))),
              child: const Icon(Icons.close_rounded, size: 18, color: jRed),
            ),
          ),
        ),
      );
}