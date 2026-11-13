import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/runpass_theme.dart';

void main() {
  testWidgets(
    'menu inferior: Início, Medalhas, Corridas e Perfil, nessa ordem',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            bottomNavigationBar: RunPassBottomNav(selectedIndex: 0),
          ),
        ),
      );
      final labels = tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((d) => d.label)
          .toList();
      expect(labels, ['Início', 'Medalhas', 'Corridas', 'Perfil']);
    },
  );

  testWidgets('na aba Perfil não há realce atrás da foto', (tester) async {
    Future<Color?> indicatorAt(int index) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            bottomNavigationBar: RunPassBottomNav(selectedIndex: index),
          ),
        ),
      );
      return NavigationBarTheme.of(tester.element(find.byType(NavigationBar)))
          .indicatorColor;
    }

    expect(await indicatorAt(3), Colors.transparent);
    expect(await indicatorAt(0), isNot(Colors.transparent));
  });
}
