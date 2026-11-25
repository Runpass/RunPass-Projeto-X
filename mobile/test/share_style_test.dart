import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/post_card.dart';
import 'package:runpass/share_editor.dart';

/// Escolhas da imagem para compartilhar (faixas ou sobre a foto, medalha e ícone). Dados fictícios [FICTICIA].

/// PNG 1x1 montado na hora (a prévia precisa de uma imagem de verdade).
Future<Uint8List> _makePng() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 1, 1),
    Paint()..color = const Color(0xffff0000),
  );
  final image = await recorder.endRecording().toImage(1, 1);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
}

Future<(int, int)> sizeOf(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  return (image.width, image.height);
}

void main() {
  testWidgets(
    'faixas: 1080 x 1920 sem foto; sobre a foto: 1080 x 1550 (sem a faixa de informações)',
    (tester) async {
      await tester.runAsync(() async {
        final bands = await buildShareCard(
          title: 'Corrida [FICTICIA]',
          distance: '5 km',
          time: '30:00',
          pace: '6:00/km',
        );
        final overlay = await buildShareCard(
          title: 'Corrida [FICTICIA]',
          distance: '5 km',
          time: '30:00',
          pace: '6:00/km',
          style: const ShareStyle(info: ShareInfoLayout.overlay),
        );
        expect(await sizeOf(bands), (1080, 1920));
        expect(await sizeOf(overlay), (1080, 1550));
      });
    },
  );

  testWidgets('medalha e ícone não mudam o tamanho da imagem', (tester) async {
    await tester.runAsync(() async {
      final plain = await buildShareCard(
        title: 'Corrida [FICTICIA]',
        distance: '5 km',
        time: '30:00',
        pace: '6:00/km',
        style: const ShareStyle(info: ShareInfoLayout.overlay),
      );
      final decorated = await buildShareCard(
        title: 'Corrida [FICTICIA]',
        distance: '5 km',
        time: '30:00',
        pace: '6:00/km',
        style: const ShareStyle(
          info: ShareInfoLayout.overlay,
          medalCorner: ShareCorner.bottomRight,
          sticker: ShareSticker.trophy,
          stickerCorner: ShareCorner.topLeft,
        ),
        // Bytes que não são imagem: a medalha é ignorada, sem quebrar a montagem.
        medalBytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(await sizeOf(decorated), await sizeOf(plain));
      expect(await sizeOf(decorated), (1080, 1550));
    });
  });

  testWidgets(
    'tela Compartilhar: escolhe sobre a foto, medalha no canto e estrela; devolve o estilo',
    (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final onePixelPng = (await tester.runAsync(_makePng))!;
      final drawn = <ShareStyle>[];
      final saved = shareCardBuilder;
      addTearDown(() => shareCardBuilder = saved);
      shareCardBuilder =
          ({
            required title,
            required distance,
            required time,
            required pace,
            photoBytes,
            ShareStyle style = const ShareStyle(),
            medalBytes,
          }) async {
            drawn.add(style);
            return onePixelPng;
          };
      ShareStyle? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  chosen = await Navigator.of(context).push<ShareStyle>(
                    MaterialPageRoute<ShareStyle>(
                      builder: (_) => ShareEditorScreen(
                        title: 'Corrida [FICTICIA]',
                        distance: '5 km',
                        time: '30:00',
                        pace: '6:00/km',
                        medalBytes: Uint8List.fromList([1, 2, 3]),
                      ),
                    ),
                  );
                },
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(drawn.last.info, ShareInfoLayout.bands); // padrão: faixas

      await tester.tap(find.text('Sobre a foto'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('share-medal-bottomRight')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('share-sticker-star')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('share-sticker-corner-topLeft')));
      await tester.pumpAndSettle();
      expect(drawn.last.info, ShareInfoLayout.overlay);
      expect(drawn.last.medalCorner, ShareCorner.bottomRight);
      expect(drawn.last.sticker, ShareSticker.star);
      expect(drawn.last.stickerCorner, ShareCorner.topLeft);
      expect(find.byKey(const Key('share-preview')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('share-send')));
      await tester.tap(find.byKey(const Key('share-send')));
      await tester.pumpAndSettle();
      expect(chosen?.info, ShareInfoLayout.overlay);
      expect(chosen?.medalCorner, ShareCorner.bottomRight);
      expect(chosen?.sticker, ShareSticker.star);
    },
  );

  testWidgets('sem foto da medalha, os cantos da medalha ficam desligados', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final onePixelPng = (await tester.runAsync(_makePng))!;
    final saved = shareCardBuilder;
    addTearDown(() => shareCardBuilder = saved);
    shareCardBuilder = ({
      required title,
      required distance,
      required time,
      required pace,
      photoBytes,
      ShareStyle style = const ShareStyle(),
      medalBytes,
    }) async => onePixelPng;
    await tester.pumpWidget(
      const MaterialApp(
        home: ShareEditorScreen(
          title: 'Corrida [FICTICIA]',
          distance: '5 km',
          time: '30:00',
          pace: '6:00/km',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chip = tester.widget<ChoiceChip>(
      find.byKey(const Key('share-medal-topLeft')),
    );
    expect(chip.onSelected, isNull);
    expect(find.text('Esta corrida não tem foto da medalha.'), findsOneWidget);
  });
}
