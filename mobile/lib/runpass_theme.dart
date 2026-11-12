import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'podium_logo.dart';

const runPassOrange = Color(0xfffc5426);
const runPassGold = Color(0xffe8b23a);
const runPassNavy = Color(0xff101b2b);
const runPassMist = Color(0xfff5f7fa);

ThemeData runPassTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: runPassOrange,
    brightness: Brightness.light,
    surface: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme.copyWith(primary: runPassOrange),
    scaffoldBackgroundColor: runPassMist,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: runPassNavy,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xffe3e7ed)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: runPassOrange,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: Color(0xffffe4dc),
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
    ),
  );
}

/// Modo escuro escolhido em Configuracoes; lembrado entre aberturas do app.
class ThemeController {
  static const _key = 'dark-mode';
  static final dark = ValueNotifier<bool>(false);

  static Future<void> load() async {
    try {
      dark.value =
          (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } on Object {
      dark.value = false;
    }
  }

  static Future<void> set(bool value) async {
    dark.value = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, value);
    } on Object {
      // Vale ate fechar o app.
    }
  }
}

/// Tema escuro de todo o app (ligado em Configuracoes).
ThemeData runPassDarkTheme() {
  const surface = Color(0xff1a1a1d);
  final scheme = ColorScheme.fromSeed(
    seedColor: runPassOrange,
    brightness: Brightness.dark,
    surface: surface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme.copyWith(primary: runPassOrange),
    scaffoldBackgroundColor: const Color(0xff0e0e10),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xff0e0e10),
      foregroundColor: Colors.white,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surface,
      selectedColor: runPassOrange,
      labelStyle: const TextStyle(color: Colors.white),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xff33363b)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: runPassOrange,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Color(0xff0e0e10),
      indicatorColor: Color(0xff3a2a22),
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
    ),
  );
}

class RunPassWordmark extends StatelessWidget {
  final bool compact;
  const RunPassWordmark({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      PodiumLogo(size: compact ? 28 : 38),
      const SizedBox(width: 5),
      RichText(
        text: TextSpan(
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: compact ? 25 : 34,
            letterSpacing: -1.4,
            color: context.isDark ? Colors.white : runPassNavy,
          ),
          children: const [
            TextSpan(text: 'Meu'),
            TextSpan(
              text: 'Pódio',
              style: TextStyle(color: runPassOrange),
            ),
          ],
        ),
      ),
    ],
  );
}

class RunPassBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int>? onDestinationSelected;
  const RunPassBottomNav({
    super.key,
    required this.selectedIndex,
    this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) => NavigationBar(
    selectedIndex: selectedIndex,
    onDestinationSelected: onDestinationSelected,
    destinations: const [
      NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Início'),
      NavigationDestination(
        icon: Icon(Icons.directions_run),
        label: 'Corridas',
      ),
      NavigationDestination(
        icon: Icon(Icons.emoji_events_outlined),
        label: 'Medalhas',
      ),
      NavigationDestination(icon: Icon(Icons.person_outline), label: 'Perfil'),
    ],
  );
}

/// Cores que mudam entre o tema claro e o escuro. Cores fixas de "fundo claro" nao podem ser
/// usadas direto nas telas, senao ficam ilegiveis no modo escuro.
extension RunPassPalette on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
  Color get muted => isDark ? Colors.white70 : Colors.black54;
  Color get softFill =>
      isDark ? const Color(0xff3a2a22) : const Color(0xffffe4dc);
  Color get panel => isDark ? const Color(0xff26282c) : const Color(0xffe9ecf1);
  Color get panelStrong =>
      isDark ? const Color(0xff303338) : const Color(0xffd5d8dd);
  Color get panelCard =>
      isDark ? const Color(0xff202226) : const Color(0xffe6e8eb);
  Color get archivedText =>
      isDark ? const Color(0xff9aa0aa) : const Color(0xff7a808a);
  Color get greenFill =>
      isDark ? const Color(0xff17301f) : const Color(0xffe6f6ec);
  Color get warnFill =>
      isDark ? const Color(0xff33281a) : const Color(0xfffff3e0);
  Color get track => isDark ? const Color(0xff33363b) : const Color(0xffeceff3);
  Color get onSurfaceText => Theme.of(this).colorScheme.onSurface;
}

/// Navegador global: permite abrir uma tela a partir de um toque no aviso do celular.
final GlobalKey<NavigatorState> runPassNavigatorKey =
    GlobalKey<NavigatorState>();
