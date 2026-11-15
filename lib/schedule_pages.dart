import 'package:flutter/material.dart';

import 'home_page.dart';
import 'kaluga.dart';
import 'main.dart';
import 'web_page.dart';

class ScheduleMenuPage extends StatelessWidget {
  const ScheduleMenuPage({super.key});
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        children: [
          const PageHeader('Расписание транспорта', 'Калуга · данные kaluga.ru'),
          for (final s in kSources)
            Tile(
              icon: s.id <= 68 ? Icons.train_rounded : Icons.directions_bus_filled_rounded,
              title: s.title,
              subtitle: s.subtitle,
              onTap: () => Navigator.pushNamed(context, '/station', arguments: s),
            ),
        ],
      );
}

class StationPage extends StatefulWidget {
  const StationPage({super.key, required this.src});
  final KalugaSource src;
  @override
  State<StationPage> createState() => _StationPageState();
}

class _StationPageState extends State<StationPage> {
  late Future<Schedule> _f = loadSchedule(widget.src);
  String _q = '';

  void _reload() => setState(() => _f = loadSchedule(widget.src, force: true));

  void _openSite() => Navigator.pushNamed(context, '/web',
      arguments: WebArgs(widget.src.url, widget.src.title, clean: true));

  bool _match(SchRow r) {
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    return r.title.toLowerCase().contains(q) || r.route.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Schedule>(
        future: _f,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _Fallback(
              icon: Icons.wifi_off_rounded,
              text: 'Не удалось загрузить расписание',
              onRetry: _reload,
              onSite: _openSite,
            );
          }
          final s = snap.data!;
          if (s.mode == ParseMode.failed || s.sections.isEmpty) {
            return _Fallback(
              icon: Icons.build_circle_outlined,
              text: 'Не удалось прочитать расписание. Открою сайт как есть.',
              onRetry: _reload,
              onSite: _openSite,
            );
          }
          final n = s.sections.length;
          return DefaultTabController(
            length: n,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.title, style: context.t.titleLarge),
                      if (s.updated.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(s.updated, style: context.t.bodySmall),
                        ),
                    ]),
                  ),
                  IconButton(onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v.trim()),
                  decoration: InputDecoration(
                    hintText: 'Поиск: направление или номер',
                    prefixIcon: const Icon(Icons.search_rounded),
                    isDense: true,
                    filled: true,
                    fillColor: context.c.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: context.c.outlineVariant),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: context.c.outlineVariant),
                    ),
                  ),
                ),
              ),
              if (n > 1)
                TabBar(
                  isScrollable: true,
                  labelColor: context.c.primary,
                  unselectedLabelColor: context.c.onSurfaceVariant,
                  indicatorColor: context.c.primary,
                  tabAlignment: TabAlignment.start,
                  tabs: [for (final sec in s.sections) Tab(text: sec.title)],
                ),
              Expanded(
                child: TabBarView(children: [
                  for (final sec in s.sections) _SectionList(section: sec, match: _match),
                ]),
              ),
            ]),
          );
        },
      );
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.icon, required this.text,
                   required this.onRetry, required this.onSite});
  final IconData icon;
  final String text;
  final VoidCallback onRetry, onSite;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: context.c.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onSite, child: const Text('Открыть расписание')),
            TextButton(onPressed: onRetry, child: const Text('Попробовать снова')),
          ]),
        ),
      );
}

class _SectionList extends StatelessWidget {
  const _SectionList({required this.section, required this.match});
  final Section section;
  final bool Function(SchRow) match;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (final g in section.groups) {
      final rows = g.rows.where(match).toList();
      if (rows.isEmpty) continue;
      if (g.title.isNotEmpty) {
        items.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(g.title, style: context.t.titleMedium),
        ));
      }
      for (final r in rows) { items.add(RowCard(r)); }
    }
    if (items.isEmpty) {
      return Center(child: Text('Ничего не найдено', style: context.t.bodySmall));
    }
    return ListView(padding: const EdgeInsets.only(top: 8, bottom: 24), children: items);
  }
}

class RowCard extends StatelessWidget {
  const RowCard(this.r, {super.key});
  final SchRow r;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.c.outlineVariant),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (r.route.isNotEmpty)
              SizedBox(
                width: 76,
                child: Text(r.route,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.c.primary)),
              ),
            Expanded(child: Text(r.title, style: context.t.titleMedium)),
          ]),
          if (r.times.isNotEmpty) const SizedBox(height: 10),
          Wrap(spacing: 12, runSpacing: 8, children: [
            for (final t in r.times)
              SizedBox(
                width: 132,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (t.label.isNotEmpty)
                    Text(t.label,
                        style: context.t.bodySmall,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(t.value,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: context.c.onSurface)),
                  if (t.old.isNotEmpty)
                    Text('было ${t.old}',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: context.c.onSurfaceVariant,
                            decoration: TextDecoration.lineThrough)),
                ]),
              ),
          ]),
          if (r.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(r.note, style: context.t.bodySmall),
            ),
        ]),
      );
}
