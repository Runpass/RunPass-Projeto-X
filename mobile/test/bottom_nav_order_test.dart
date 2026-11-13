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
}
