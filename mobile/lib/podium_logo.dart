import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'runpass_theme.dart';

/// Marca do MeuPódio: um pódio (2º, 1º e 3º lugares) com a estrela do campeão no topo.
/// Desenhada em código para valer no app, nos ícones de instalação e, igual, no portal.
/// Coordenadas em fração do quadrado (0 a 1); `scale` encolhe a marca no centro (ícones
/// com margem de segurança).
class PodiumPainter extends CustomPainter {
  final double scale;
  const PodiumPainter({this.scale = 1});

  static const gold = Color(0xffffc144);

  /// Degraus: (esquerda, direita, topo) na ordem 2º, 1º, 3º; todos assentados em y = 0.84.
  static const steps = [
    (0.12, 0.38, 0.54, Color(0xffff8a5c)),
    (0.38, 0.62, 0.38, runPassOrange),
    (0.62, 0.88, 0.64, Color(0xffe8431a)),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.translate(side * (1 - scale) / 2, side * (1 - scale) / 2);
    canvas.scale(side * scale);
    const baseline = 0.84, radius = 0.035;
    for (final (left, right, top, color) in steps) {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          left,
          top,
          right,
          baseline,
          topLeft: const Radius.circular(radius),
          topRight: const Radius.circular(radius),
        ),
        Paint()..color = color,
      );
    }
    // Estrela do campeão sobre o degrau do meio.
    final star = Path();
    const cx = 0.5, cy = 0.215, outer = 0.125, inner = 0.052;
    for (var i = 0; i < 10; i++) {
      final r = i.isEven ? outer : inner;
      final a = -math.pi / 2 + i * math.pi / 5;
      final x = cx + r * math.cos(a), y = cy + r * math.sin(a);
      i == 0 ? star.moveTo(x, y) : star.lineTo(x, y);
    }
    canvas.drawPath(star..close(), Paint()..color = gold);
    canvas.restore();
  }

  @override
  bool shouldRepaint(PodiumPainter old) => old.scale != scale;
}

class PodiumLogo extends StatelessWidget {
  final double size;
  const PodiumLogo({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'MeuPódio',
    image: true,
    child: SizedBox(
      key: const Key('podium-logo'),
      width: size,
      height: size,
      child: const CustomPaint(painter: PodiumPainter()),
    ),
  );
}
