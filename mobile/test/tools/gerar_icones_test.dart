// Ferramenta (não é teste de verdade): regenera os ícones de instalação do iOS, Android e web
// com o logo do pódio. Só roda com a variável GERAR_ICONES=1:
//   GERAR_ICONES=1 flutter test test/tools/gerar_icones_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/podium_logo.dart';
import 'package:runpass/runpass_theme.dart';

Future<List<int>> render(int px, double scale) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(px.toDouble(), px.toDouble());
  canvas.drawRect(Offset.zero & size, Paint()..color = runPassNavy);
  PodiumPainter(scale: scale).paint(canvas, size);
  final image = await recorder.endRecording().toImage(px, px);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('gera os ícones do app com o logo do pódio', (tester) async {
    await tester.runAsync(() async {
      final targets = <String, (int, double)>{};
      // iOS: tamanhos do Contents.json (tamanho x escala).
      final iosDir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      final contents = jsonDecode(
        File('$iosDir/Contents.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      for (final item in contents['images'] as List) {
        final size = double.parse((item['size'] as String).split('x').first);
        final scale = int.parse((item['scale'] as String).replaceAll('x', ''));
        targets['$iosDir/${item['filename']}'] = ((size * scale).round(), 0.9);
      }
      // Android.
      const res = 'android/app/src/main/res';
      for (final e in {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      }.entries) {
        targets['$res/mipmap-${e.key}/ic_launcher.png'] = (e.value, 0.9);
      }
      // Web (os "maskable" precisam de margem de segurança maior).
      targets['web/favicon.png'] = (32, 0.95);
      targets['web/icons/Icon-192.png'] = (192, 0.9);
      targets['web/icons/Icon-512.png'] = (512, 0.9);
      targets['web/icons/Icon-maskable-192.png'] = (192, 0.62);
      targets['web/icons/Icon-maskable-512.png'] = (512, 0.62);
      for (final entry in targets.entries) {
        File(entry.key)
            .writeAsBytesSync(await render(entry.value.$1, entry.value.$2));
      }
      stdout.writeln('${targets.length} ícones gerados');
    });
  }, skip: Platform.environment['GERAR_ICONES'] == null);
}
