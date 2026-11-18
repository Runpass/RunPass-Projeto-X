import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/profile_photo.dart';

// PNG 1x1 (dados sintéticos).
final png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0x00,
  0x00,
  0x03,
  0x01,
  0x01,
  0x00,
  0xC9,
  0xFE,
  0x92,
  0xEF,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

void main() {
  testWidgets(
    'foto da publicação: inteira, sem recorte; + e − só ampliam a visualização',
    (tester) async {
      List<int>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<List<int>>(
                  MaterialPageRoute(
                    builder: (_) => PhotoZoomScreen(image: png),
                  ),
                );
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      // Sem quadro de recorte nem proporções.
      expect(find.text('Livre'), findsNothing);
      expect(find.text('Feed 16:10'), findsNothing);
      final zoomOut = find.byKey(const Key('photo-zoom-out'));
      expect(
        tester.widget<IconButton>(zoomOut).onPressed,
        isNull,
      ); // já está na foto inteira
      await tester.tap(find.byKey(const Key('photo-zoom-in')));
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(zoomOut).onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('photo-zoom-use')));
      await tester.pumpAndSettle();
      expect(result, png); // sempre a foto original, inteira
    },
  );

  testWidgets(
    'recortar é opcional e discreto: mostra os tamanhos e volta para a foto inteira',
    (tester) async {
      await tester.pumpWidget(MaterialApp(home: PhotoZoomScreen(image: png)));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Use + e −'),
        findsNothing,
      ); // sem texto de instrução
      expect(find.byKey(const Key('crop-aspect-0')), findsNothing);
      await tester.tap(find.byKey(const Key('photo-crop')));
      await tester.pump();
      expect(find.text('Livre'), findsOneWidget);
      expect(find.text('Feed 16:10'), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-crop-off')));
      await tester.pump();
      expect(find.byKey(const Key('crop-aspect-0')), findsNothing);
      expect(find.byKey(const Key('photo-zoom-viewer')), findsOneWidget);
    },
  );
}
