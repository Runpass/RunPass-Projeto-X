import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:runpass/profile_photo.dart';

/// Quadrado (40x40) com uma cor diferente em cada quadrante — permite provar
/// que um giro de verdade MOVE o conteudo (nao so muda de tela sem mudar
/// nada, ja que a pinça do pacote antigo so dava zoom, nunca rotacionava).
Uint8List _fourQuadrantsPng() {
  final image = img.Image(width: 40, height: 40);
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: 19,
    y2: 19,
    color: img.ColorRgb8(255, 0, 0), // vermelho: topo-esquerda
  );
  img.fillRect(
    image,
    x1: 20,
    y1: 0,
    x2: 39,
    y2: 19,
    color: img.ColorRgb8(0, 255, 0), // verde: topo-direita
  );
  img.fillRect(
    image,
    x1: 0,
    y1: 20,
    x2: 19,
    y2: 39,
    color: img.ColorRgb8(0, 0, 255), // azul: baixo-esquerda
  );
  img.fillRect(
    image,
    x1: 20,
    y1: 20,
    x2: 39,
    y2: 39,
    color: img.ColorRgb8(255, 255, 0), // amarelo: baixo-direita
  );
  return Uint8List.fromList(img.encodePng(image));
}

bool _closeTo(img.Color c, int r, int g, int b) =>
    (c.r - r).abs() < 40 && (c.g - g).abs() < 40 && (c.b - b).abs() < 40;

void main() {
  testWidgets(
    'tela de recortar a foto de perfil gira com o gesto de dois dedos '
    '(pinça), igual ao recorte da medalha — não só dá zoom como o pacote '
    'antigo (crop_your_image) fazia',
    (tester) async {
      final original = _fourQuadrantsPng();
      List<int>? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<List<int>>(
                    MaterialPageRoute(
                      builder: (_) => ProfilePhotoCropScreen(image: original),
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
      // Nao usa `pumpAndSettle` aqui: enquanto a imagem nao decodifica, a
      // tela mostra um `CircularProgressIndicator` (giro indeterminado, sem
      // fim) — `pumpAndSettle` esperaria essa animacao "parar" pra sempre.
      await tester.pump(); // agenda o frame da transicao de rota
      await tester.pump(
        const Duration(milliseconds: 300),
      ); // a transicao termina

      // Decodificar a imagem (dart:ui) e um Future de verdade, fora do
      // relogio falso do `pump`: precisa de tempo real passando.
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });

      final touchArea = tester.widget<GestureDetector>(
        find.byKey(const Key('crop-touch-area')),
      );
      touchArea.onScaleStart!(ScaleStartDetails());
      touchArea.onScaleUpdate!(
        ScaleUpdateDetails(
          rotation: pi / 2,
          scale: 1,
          focalPointDelta: Offset.zero,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('crop-confirm')));
      // A exportacao (`toImage`/`toByteData`) tambem e assincrona de verdade.
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      expect(tester.takeException(), isNull);

      expect(result, isNotNull);
      final rotated = img.decodeImage(Uint8List.fromList(result!))!;
      final w = rotated.width, h = rotated.height;

      // Giro de 90°: quem estava no topo-esquerda (vermelho) vai pro
      // topo-direita; baixo-esquerda (azul) vai pro topo-esquerda; e assim
      // por diante — uma permutacao dos quadrantes, nao mais a identidade.
      expect(
        _closeTo(
          rotated.getPixel((w * 0.25).round(), (h * 0.25).round()),
          0,
          0,
          255,
        ),
        isTrue,
        reason: 'topo-esquerda devia ser azul (vinha do baixo-esquerda)',
      );
      expect(
        _closeTo(
          rotated.getPixel((w * 0.75).round(), (h * 0.25).round()),
          255,
          0,
          0,
        ),
        isTrue,
        reason: 'topo-direita devia ser vermelho (vinha do topo-esquerda)',
      );
      expect(
        _closeTo(
          rotated.getPixel((w * 0.25).round(), (h * 0.75).round()),
          255,
          255,
          0,
        ),
        isTrue,
        reason: 'baixo-esquerda devia ser amarelo (vinha do baixo-direita)',
      );
      expect(
        _closeTo(
          rotated.getPixel((w * 0.75).round(), (h * 0.75).round()),
          0,
          255,
          0,
        ),
        isTrue,
        reason: 'baixo-direita devia ser verde (vinha do topo-direita)',
      );
    },
  );
}
