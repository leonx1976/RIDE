import 'dart:async';
import 'dart:io' show exit;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'compass.dart';
import 'home_page.dart';
import 'kaluga.dart';
import 'navigator.dart';
import 'routes_map.dart';
import 'schedule_pages.dart';
import 'traffic.dart';
import 'weather.dart';
import 'web_page.dart';

final navKey = GlobalKey<NavigatorState>();

extension AppColors on BuildContext {
  ColorScheme get c => Theme.of(this).colorScheme;
  TextTheme get t => Theme.of(this).textTheme;
}

class ThemeCtrl extends ChangeNotifier {
  ThemeCtrl._();
  static final instance = ThemeCtrl._();
  ThemeMode mode = ThemeMode.light;
  bool get isDark => mode == ThemeMode.dark;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      mode = p.getString('theme_mode') == 'dark' ? ThemeMode.dark : ThemeMode.light;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> toggle() async {
    mode = isDark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('theme_mode', isDark ? 'dark' : 'light');
    } catch (_) {}
  }
}

const _accentLight = Color(0xFF1668D6);
const _accentDark = Color(0xFF6AA6FF);

ThemeData buildTheme(Brightness b) {
  final light = b == Brightness.light;
  final text = light ? const Color(0xFF1B2733) : const Color(0xFFE6EAF0);
  final muted = light ? const Color(0xFF6B7A8C) : const Color(0xFF9AA7B4);
  final scheme = ColorScheme.fromSeed(seedColor: _accentLight, brightness: b).copyWith(
    primary: light ? _accentLight : _accentDark,
    surface: light ? Colors.white : const Color(0xFF1A1F26),
    onSurface: text,
    onSurfaceVariant: muted,
    outlineVariant: light ? const Color(0xFFE3E9EF) : const Color(0xFF2C333D),
    error: const Color(0xFFD64545),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: light ? const Color(0xFFF2F5F8) : const Color(0xFF10141A),
    dividerColor: scheme.outlineVariant,
    textTheme: TextTheme(
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: text),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: text),
      bodyMedium: TextStyle(fontSize: 14, color: text),
      bodySmall: TextStyle(fontSize: 12.5, color: muted),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeCtrl.instance.load();
  await CompassService.instance.load();
  runApp(const FamilyApp());
}

class FamilyApp extends StatelessWidget {
  const FamilyApp({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ThemeCtrl.instance,
        builder: (context, _) => MaterialApp(
          title: 'Калуга',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: ThemeCtrl.instance.mode,
          home: const Shell(),
        ),
      );
}

class WebNav extends ChangeNotifier {
  WebNav._();
  static final instance = WebNav._();
  WebViewController? _c;
  bool canBack = false, canForward = false;

  void attach(WebViewController c) { _c = c; refresh(); }
  void detach(WebViewController c) {
    if (identical(_c, c)) { _c = null; canBack = canForward = false; touch(); }
  }
  void clear() { _c = null; canBack = canForward = false; touch(); }
  void touch() => WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());

  Future<void> refresh() async {
    final c = _c;
    if (c == null) {
      canBack = canForward = false;
    } else {
      canBack = await c.canGoBack();
      canForward = await c.canGoForward();
    }
    touch();
  }

  Future<void> back() async {
    final c = _c;
    if (c != null && await c.canGoBack()) { await c.goBack(); await refresh(); return; }
    navKey.currentState?.maybePop();
  }

  Future<void> forward() async {
    final c = _c;
    if (c != null && await c.canGoForward()) { await c.goForward(); await refresh(); }
  }
}

class NavWatcher extends NavigatorObserver {
  @override void didPush(Route r, Route? p) => WebNav.instance.touch();
  @override void didPop(Route r, Route? p) => WebNav.instance.touch();
  @override void didRemove(Route r, Route? p) => WebNav.instance.touch();
}

void forceExit() {
  SystemNavigator.pop();
  Timer.run(() => exit(0));
}

class Shell extends StatelessWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: Theme.of(context).scaffoldBackgroundColor,
        systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      ),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;
          if (WebNav.instance.canBack) { await WebNav.instance.back(); return; }
          final nav = navKey.currentState;
          if (nav != null && nav.canPop()) { nav.pop(); return; }
          forceExit();
        },
        child: Scaffold(
          body: SafeArea(
            child: Column(children: [
              const TopBar(),
              Expanded(
                child: Navigator(
                  key: navKey,
                  initialRoute: '/',
                  observers: [NavWatcher()],
                  onGenerateRoute: (s) {
                    Widget page;
                    switch (s.name) {
                      case '/weather':  page = const WeatherPage(); break;
                      case '/schedule': page = const ScheduleMenuPage(); break;
                      case '/station':  page = StationPage(src: s.arguments as KalugaSource); break;
                      case '/card':     page = const CardPage(); break;
                      case '/navi':     page = const NaviPage(); break;
                      case '/routes':   page = const RoutesListPage(); break;
                      case '/routemap': page = RouteMapPage(route: s.arguments as BusRoute); break;
                      case '/traffic':  page = const TrafficPage(); break;
                      case '/web':      page = WebPage(args: s.arguments as WebArgs); break;
                      default:          page = const HomePage();
                    }
                    return MaterialPageRoute(builder: (_) => page, settings: s);
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class TopBar extends StatelessWidget {
  const TopBar({super.key});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border(bottom: BorderSide(color: context.c.outlineVariant)),
      ),
      child: ListenableBuilder(
        listenable: WebNav.instance,
        builder: (context, _) {
          final web = WebNav.instance;
          final canPop = navKey.currentState?.canPop() ?? false;
          return Row(children: [
            NavBtn(Icons.home_rounded, 'Главное меню', () {
              navKey.currentState?.popUntil((r) => r.isFirst);
              web.clear();
            }),
            NavBtn(Icons.arrow_back_rounded, 'Назад',
                (web.canBack || canPop) ? () => web.back() : null),
            NavBtn(Icons.arrow_forward_rounded, 'Вперёд',
                web.canForward ? () => web.forward() : null),
            const Spacer(),
            NavBtn(dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                dark ? 'Светлая тема' : 'Тёмная тема',
                () => ThemeCtrl.instance.toggle()),
            NavBtn(Icons.close_rounded, 'Выход', forceExit, danger: true),
          ]);
        },
      ),
    );
  }
}

class NavBtn extends StatelessWidget {
  const NavBtn(this.icon, this.tip, this.onTap, {super.key, this.danger = false});
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            width: 44, height: 44,
            child: Icon(icon, size: 24,
                color: onTap == null
                    ? context.c.outlineVariant
                    : (danger ? context.c.error : context.c.onSurface)),
          ),
        ),
      );
}
