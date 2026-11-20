import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/my_races.dart';
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
    void Function(List<int>?) onResult, {
    bool withShelf = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => onResult(
                await Navigator.of(context).push<List<int>>(
                  MaterialPageRoute(
                    builder: (_) => PhotoZoomScreen(
                      image: png,
                      title: 'Foto da medalha',
                      shelf: withShelf
                          ? (key) => MedalShelfCrop(
                              key: key,
                              image: png,
                              frame: medalFrames.first,
                            )
                          : null,
                    ),
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
    if (withShelf) {
      // A prateleira decodifica a foto fora do relógio do teste (indicador girando até lá).
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 400));
    } else {
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'medalha no mesmo editor do post: abre inteira e os formatos ficam escondidos no ícone',
    (tester) async {
      await open(tester, (_) {});
      expect(find.text('Foto da medalha'), findsOneWidget);
      expect(find.byKey(const Key('photo-zoom-viewer')), findsOneWidget);
      expect(find.byKey(const Key('photo-formats')), findsNothing);
      await tester.tap(find.byKey(const Key('photo-crop')));
      await tester.pumpAndSettle();
      for (final label in [
        'Foto inteira',
        'Livre',
        '1:1',
        '4:3',
        '3:4',
        '16:9',
        'Feed 16:10',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      // Sem modelo de medalha, não há "Prateleira".
      expect(find.byKey(const Key('photo-format-shelf')), findsNothing);
      ChoiceChip chip(String key) =>
          tester.widget<ChoiceChip>(find.byKey(Key(key)));
      expect(chip('photo-format-whole').selected, isTrue);
      await tester.tap(find.byKey(const Key('crop-aspect-1')));
      await tester.pumpAndSettle();
      expect(chip('crop-aspect-1').selected, isTrue);
      expect(find.byKey(const Key('photo-zoom-viewer')), findsNothing);
      // Esconder a barra mantém o formato escolhido.
      await tester.tap(find.byKey(const Key('photo-crop-off')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-formats')), findsNothing);
      expect(find.byKey(const Key('photo-zoom-viewer')), findsNothing);
    },
  );

  testWidgets(
    'reposicionar na prateleira: o mesmo editor, aberto no formato Prateleira',
    (tester) async {
      await open(tester, (_) {}, withShelf: true);
      expect(find.text('Foto da medalha'), findsOneWidget);
      expect(find.byType(MedalShelfCrop), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-crop')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('photo-format-shelf')))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('photo-format-whole')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MedalShelfCrop), findsNothing);
      expect(find.byKey(const Key('photo-zoom-viewer')), findsOneWidget);
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
