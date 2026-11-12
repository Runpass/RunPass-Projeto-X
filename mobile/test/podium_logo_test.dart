import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/runpass_theme.dart';

void main() {
  testWidgets('o logotipo usa o pódio, não mais o corredor', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RunPassWordmark())),
    );
    expect(find.byKey(const Key('podium-logo')), findsOneWidget);
    expect(find.byIcon(Icons.directions_run_rounded), findsNothing);
    expect(find.bySemanticsLabel('MeuPódio'), findsWidgets);
    expect(find.textContaining('Meu', findRichText: true), findsOneWidget);
  });
}
