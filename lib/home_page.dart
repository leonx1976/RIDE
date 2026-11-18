import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'main.dart';
import 'web_page.dart';

const kWeatherMap =
    'https://yandex.ru/pogoda/ru/kaluga/maps/nowcast?ll=36.2274_54.5092&z=9';
const kTrafficMap =
    'https://yandex.ru/maps/6/kaluga/transport/?l=sat%2Cskl&ll=36.252414%2C54.514724&z=16';
const kRuStoreNavi = 'https://www.rustore.ru/catalog/app/ru.yandex.yandexnavi';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        children: [
          const PageHeader('Калуга', 'Всё нужное в одном месте'),
          Tile(
            icon: Icons.wb_cloudy_rounded,
            title: 'Карта погоды',
            subtitle: 'Осадки в реальном времени',
            onTap: () => Navigator.pushNamed(context, '/web',
                arguments: WebArgs(kWeatherMap, 'Карта погоды', hideChrome: true)),
          ),
          Tile(
            icon: Icons.navigation_rounded,
            title: 'Навигатор',
            subtitle: 'Пешеходный · работает офлайн',
            onTap: () => Navigator.pushNamed(context, '/navi'),
            onLongPress: () => openYandexNavi(context),
          ),
          Tile(
            icon: Icons.directions_bus_filled_rounded,
            title: 'Расписание транспорта',
            subtitle: 'Электрички и автобусы',
            onTap: () => Navigator.pushNamed(context, '/schedule'),
          ),
          Tile(
            icon: Icons.route_rounded,
            title: 'Карта маршрутов',
            subtitle: 'Схемы рейсов на карте',
            onTap: () => Navigator.pushNamed(context, '/routes'),
          ),
          Tile(
            icon: Icons.commute_rounded,
            title: 'Движение транспорта',
            subtitle: 'Автобусы и троллейбусы онлайн',
            onTap: () => Navigator.pushNamed(context, '/web',
                arguments: WebArgs(kTrafficMap, 'Движение транспорта', hideChrome: true)),
          ),
          Tile(
            icon: Icons.credit_card_rounded,
            title: 'Транспортная карта',
            subtitle: 'Баланс и пополнение',
            onTap: () => Navigator.pushNamed(context, '/card'),
          ),
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

Future<void> openYandexNavi(BuildContext context) async {
  if (await _tryLaunch('yandexnavi://')) return;
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Яндекс Навигатор не установлен'),
      content: const Text('Открыть его страницу в RuStore?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Открыть')),
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
        padding: const EdgeInsets.only(bottom: 18),
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
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Container(
              height: 76,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: context.c.outlineVariant),
              ),
              child: Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: context.c.primary.withOpacity(.12),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(icon, color: context.c.primary, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: context.t.titleMedium,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
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
