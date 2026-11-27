import 'dart:math' show pi;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/my_races.dart';

/// Imagem 4x4 com 4 quadrantes de cores diferentes, pra conseguir checar se
/// giro/zoom/arrasto levam o pixel certo pro lugar certo.
Future<ui.Image> quadrantImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 2, 2),
    Paint()..color = const Color(0xffff0000), // vermelho: cima-esquerda
  );
  canvas.drawRect(
    const Rect.fromLTWH(2, 0, 2, 2),
    Paint()..color = const Color(0xff00ff00), // verde: cima-direita
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 2, 2, 2),
    Paint()..color = const Color(0xff0000ff), // azul: baixo-esquerda
  );
  canvas.drawRect(
    const Rect.fromLTWH(2, 2, 2, 2),
    Paint()..color = const Color(0xffffff00), // amarelo: baixo-direita
  );
  return recorder.endRecording().toImage(4, 4);
}

Future<Color> pixelAt(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final i = (y * image.width + x) * 4;
  final bytes = data!.buffer.asUint8List();
  return Color.fromARGB(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
}

void main() {
  test(
    'TouchCropPainter: sem transformacao mantem os 4 cantos no lugar',
    () async {
      final image = await quadrantImage();
      const size = 40.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      TouchCropPainter(
        image: image,
        scale: 1,
        rotation: 0,
        offset: Offset.zero,
      ).paint(canvas, const Size(size, size));
      final output = await recorder.endRecording().toImage(
        size.round(),
        size.round(),
      );

      expect(await pixelAt(output, 5, 5), const Color(0xffff0000)); // cima-esq
      expect(await pixelAt(output, 34, 5), const Color(0xff00ff00)); // cima-dir
      expect(
        await pixelAt(output, 5, 34),
        const Color(0xff0000ff),
      ); // baixo-esq
      expect(
        await pixelAt(output, 34, 34),
        const Color(0xffffff00),
      ); // baixo-dir
    },
  );

  test(
    'TouchCropPainter: girar 90 graus no sentido horario roda os cantos junto',
    () async {
      final image = await quadrantImage();
      const size = 40.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      TouchCropPainter(
        image: image,
        scale: 1,
        rotation: pi / 2,
        offset: Offset.zero,
      ).paint(canvas, const Size(size, size));
      final output = await recorder.endRecording().toImage(
        size.round(),
        size.round(),
      );

      // Girando 90 graus no sentido horario, o canto de cima-esquerda
      // (vermelho) vai para cima-direita.
      expect(await pixelAt(output, 34, 5), const Color(0xffff0000));
      expect(await pixelAt(output, 34, 34), const Color(0xff00ff00));
      expect(await pixelAt(output, 5, 5), const Color(0xff0000ff));
      expect(await pixelAt(output, 5, 34), const Color(0xffffff00));
    },
  );

  test(
    'TouchCropPainter: arrastar (offset) desloca a foto na mesma direcao',
    () async {
      final image = await quadrantImage();
      const size = 40.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      TouchCropPainter(
        image: image,
        scale: 1,
        rotation: 0,
        offset: const Offset(20, 0),
      ).paint(canvas, const Size(size, size));
      final output = await recorder.endRecording().toImage(
        size.round(),
        size.round(),
      );

      // Arrastando 20px pra direita, o canto de cima-esquerda (vermelho) some
      // da borda esquerda e o fundo passa a aparecer ali (fora da imagem).
      final farLeft = await pixelAt(output, 2, 5);
      expect(farLeft, isNot(const Color(0xffff0000)));
    },
  );
}
