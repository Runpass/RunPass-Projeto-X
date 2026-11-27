import 'package:flutter/material.dart';

import 'runpass_theme.dart';

/// Marca do +1Pódio (o "1" laranja com o corredor e o "+"). São imagens do pacote: a versão clara tem o
/// "+" preto e a escura tem o "+" branco, para valer sobre fundo claro e escuro.
const _markLight = 'assets/brand/mark-light.png';
const _markDark = 'assets/brand/mark-dark.png';

class PodiumLogo extends StatelessWidget {
  final double size;

  /// Força a versão para fundo escuro (cartões que têm cor própria, independente do tema).
  final bool onDark;
  const PodiumLogo({super.key, this.size = 32, this.onDark = false});

  @override
  Widget build(BuildContext context) => Semantics(
    label: '+1Pódio',
    image: true,
    child: SizedBox(
      key: const Key('podium-logo'),
      width: size,
      height: size,
      child: Image.asset(
        onDark || context.isDark ? _markDark : _markLight,
        fit: BoxFit.contain,
        excludeFromSemantics: true,
      ),
    ),
  );
}
