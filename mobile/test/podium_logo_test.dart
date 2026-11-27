import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/podium_logo.dart';
import 'package:runpass/runpass_theme.dart';

Image assetOf(WidgetTester tester, Finder f) =>
    tester.widget<Image>(find.descendant(of: f, matching: find.byType(Image)));

String nameOf(Image i) => (i.image as AssetImage).assetName;

void main() {
  testWidgets('o logotipo +1Pódio é a imagem, clara no tema claro', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RunPassWordmark())),
    );
    expect(find.byKey(const Key('podium-logo')), findsOneWidget);
    expect(find.bySemanticsLabel('+1Pódio'), findsWidgets);
    expect(
      nameOf(tester.widget<Image>(find.byType(Image))),
      'assets/brand/logo-light.png',
    );
  });

  testWidgets('no tema escuro o logotipo tem o texto branco', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const Scaffold(body: RunPassWordmark(compact: true)),
      ),
    );
    expect(
      nameOf(tester.widget<Image>(find.byType(Image))),
      'assets/brand/logo-dark.png',
    );
  });

  testWidgets('a marca em cartão escuro usa a versão para fundo escuro', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PodiumLogo(onDark: true))),
    );
    expect(
      nameOf(assetOf(tester, find.byKey(const Key('podium-logo')))),
      'assets/brand/mark-dark.png',
    );
  });
}
