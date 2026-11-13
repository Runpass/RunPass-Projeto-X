import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Quantas colunas a grade de fotos/cards mostra. A escolha fica guardada neste aparelho,
/// uma por tela (perfil e fotos da corrida); sem armazenamento vale o padrão (3).
class GridColumns {
  static const standard = 3;
  static const options = [1, 2, 3, 4, 5];

  static Future<int> read(String key, {int fallback = standard}) async {
    try {
      final saved = (await SharedPreferences.getInstance()).getInt(key);
      return saved != null && options.contains(saved) ? saved : fallback;
    } on Object {
      return fallback;
    }
  }

  static Future<void> write(String key, int value) async {
    try {
      await (await SharedPreferences.getInstance()).setInt(key, value);
    } on Object {
      // Sem armazenamento: vale até fechar a tela.
    }
  }
}

/// Botão compacto para escolher as colunas da grade (1 a 5).
class GridColumnsButton extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const GridColumnsButton({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
    key: const Key('grid-columns'),
    tooltip: 'Colunas da grade',
    icon: const Icon(Icons.grid_view_rounded, size: 20),
    padding: EdgeInsets.zero,
    onSelected: onChanged,
    itemBuilder: (_) => [
      for (final n in GridColumns.options)
        CheckedPopupMenuItem<int>(
          key: Key('grid-columns-$n'),
          value: n,
          checked: n == value,
          child: Text(n == 1 ? '1 coluna' : '$n colunas'),
        ),
    ],
  );
}
