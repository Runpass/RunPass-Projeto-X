import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'grid_columns.dart';

/// Como a lista de corridas é mostrada: cartões em lista ou em grade.
enum CatalogViewMode {
  list('Lista', Icons.view_agenda_outlined),
  grid('Grade', Icons.grid_view_rounded);

  final String label;
  final IconData icon;
  const CatalogViewMode(this.label, this.icon);

  static const storageKey = 'catalog-view-mode';

  static Future<CatalogViewMode> read([
    String key = storageKey,
    CatalogViewMode fallback = list,
  ]) async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(key);
      return values.firstWhere((m) => m.name == saved, orElse: () => fallback);
    } on Object {
      return fallback;
    }
  }

  Future<void> write([String key = storageKey]) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, name);
    } on Object {
      // Sem armazenamento: vale até fechar a tela.
    }
  }
}

/// Menu único para escolher a visualização (lista ou grade). Quando recebe `columns`, a grade também
/// oferece o número de colunas (1 a 5) no mesmo menu, sem um segundo botão.
class CatalogViewMenu extends StatelessWidget {
  final CatalogViewMode value;
  final ValueChanged<CatalogViewMode> onChanged;
  final int? columns;
  final ValueChanged<int>? onColumnsChanged;
  const CatalogViewMenu({
    super.key,
    required this.value,
    required this.onChanged,
    this.columns,
    this.onColumnsChanged,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<Object>(
    key: const Key('catalog-view-mode'),
    tooltip: 'Modo de visualização',
    icon: Icon(value.icon),
    onSelected: (choice) {
      if (choice is CatalogViewMode) onChanged(choice);
      if (choice is int) onColumnsChanged?.call(choice);
    },
    itemBuilder: (_) => [
      for (final mode in CatalogViewMode.values)
        CheckedPopupMenuItem<Object>(
          key: Key('catalog-view-${mode.name}'),
          value: mode,
          checked: mode == value,
          child: Row(
            children: [
              Icon(mode.icon, size: 20),
              const SizedBox(width: 10),
              Text(mode.label),
            ],
          ),
        ),
      if (value == CatalogViewMode.grid &&
          columns != null &&
          onColumnsChanged != null) ...[
        const PopupMenuDivider(),
        for (final n in GridColumns.options)
          CheckedPopupMenuItem<Object>(
            key: Key('grid-columns-$n'),
            value: n,
            checked: n == columns,
            child: Text(n == 1 ? '1 coluna' : '$n colunas'),
          ),
      ],
    ],
  );
}
