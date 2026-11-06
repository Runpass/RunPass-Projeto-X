import 'package:flutter/material.dart';

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

/// Dark variant used by the medal collection screen.
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
      Icon(
        Icons.directions_run_rounded,
        color: runPassOrange,
        size: compact ? 25 : 35,
      ),
      const SizedBox(width: 5),
      RichText(
        text: TextSpan(
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: compact ? 25 : 34,
            letterSpacing: -1.4,
            color: runPassNavy,
          ),
          children: const [
            TextSpan(text: 'Run'),
            TextSpan(
              text: 'Pass',
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
