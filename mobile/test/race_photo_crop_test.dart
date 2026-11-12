import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/profile_photo.dart';

// PNG 1x1 válido (vermelho), só para o recorte ter o que abrir.
final png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

void main() {
  Future<void> open(
    WidgetTester tester,
    void Function(List<int>?) onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => onResult(
                await Navigator.of(context).push<List<int>>(
                  MaterialPageRoute(
                    builder: (_) => RacePhotoCropScreen(image: png),
                  ),
                ),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'oferece livre, 1:1, 4:3, 3:4 e 16:9, com 4:3 escolhido de início',
    (tester) async {
      await open(tester, (_) {});
      for (var i = 0; i < RacePhotoCropScreen.aspects.length; i++) {
        expect(find.byKey(Key('crop-aspect-$i')), findsOneWidget);
      }
      for (final label in ['Livre', '1:1', '4:3', '3:4', '16:9']) {
        expect(find.text(label), findsOneWidget);
      }
      ChoiceChip chip(int i) =>
          tester.widget<ChoiceChip>(find.byKey(Key('crop-aspect-$i')));
      expect(chip(2).selected, isTrue);
      await tester.tap(find.byKey(const Key('crop-aspect-1')));
      await tester.pumpAndSettle();
      expect(chip(1).selected, isTrue);
      expect(chip(2).selected, isFalse);
      expect(find.textContaining('dois dedos'), findsOneWidget);
      await tester.tap(find.byKey(const Key('crop-aspect-0')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('bordas do quadro'),
        findsOneWidget,
      ); // modo livre: redimensiona o quadro
    },
  );

  testWidgets('cancelar volta sem foto: nada é enviado', (tester) async {
    var chamado = false;
    List<int>? resultado = Uint8List(1);
    await open(tester, (r) {
      chamado = true;
      resultado = r;
    });
    await tester.tap(find.byKey(const Key('crop-cancel')));
    await tester.pumpAndSettle();
    expect(chamado, isTrue);
    expect(resultado, isNull);
  });
}
