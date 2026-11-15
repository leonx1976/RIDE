import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'main.dart';
import 'weather.dart';
import 'web_page.dart';

const kRuStoreNavi = 'https://www.rustore.ru/catalog/app/ru.yandex.yandexnavi';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        children: [
          const PageHeader('Калуга', 'Всё нужное в одном месте'),
          Tile(
            icon: Icons.directions_bus_filled_rounded,
            title: 'Расписание транспорта',
            subtitle: 'Электрички и автобусы',
            onTap: () => Navigator.pushNamed(context, '/schedule'),
          ),
          Tile(
            icon: Icons.navigation_rounded,
            title: 'Навигатор',
            subtitle: 'Пешеходный маршрут · долгий тап — Яндекс Навигатор',
            onTap: () => Navigator.pushNamed(context, '/navi'),
            onLongPress: () => openNavi(context),
          ),
          Tile(
            icon: Icons.credit_card_rounded,
            title: 'Транспортная карта',
            subtitle: 'Баланс и пополнение',
            onTap: () => Navigator.pushNamed(context, '/card'),
          ),
          const SizedBox(height: 8),
          const WeatherCard(),
        ],
      );
}

Future<bool> _tryLaunch(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<void> openNavi(BuildContext context) async {
  if (await _tryLaunch('yandexnavi://')) return;
  if (!context.mounted) return;

  final go = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Навигатор не установлен'),
      content: const Text('Открыть страницу Яндекс Навигатора в RuStore?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Установить')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  if (await _tryLaunch(kRuStoreNavi)) return;
  if (!context.mounted) return;
  Navigator.pushNamed(context, '/web', arguments: WebArgs(kRuStoreNavi, 'RuStore'));
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, this.subtitle, {super.key});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: context.t.titleLarge),
          const SizedBox(height: 4),
          Text(subtitle, style: context.t.bodySmall),
        ]),
      );
}

class Tile extends StatelessWidget {
  const Tile({super.key, required this.icon, required this.title,
              required this.subtitle, required this.onTap, this.onLongPress});
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Container(
              height: 88,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: context.c.outlineVariant),
              ),
              child: Row(children: [
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: context.c.primary.withOpacity(.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: context.c.primary, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: context.t.titleMedium,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text(subtitle, style: context.t.bodySmall,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: context.c.onSurfaceVariant),
              ]),
            ),
          ),
        ),
      );
}