import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Menu para escolher a visualização (lista ou grade).
class CatalogViewMenu extends StatelessWidget {
  final CatalogViewMode value;
  final ValueChanged<CatalogViewMode> onChanged;
  const CatalogViewMenu({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<CatalogViewMode>(
    key: const Key('catalog-view-mode'),
    tooltip: 'Modo de visualização',
    icon: Icon(value.icon),
    onSelected: onChanged,
    itemBuilder: (_) => [
      for (final mode in CatalogViewMode.values)
        CheckedPopupMenuItem<CatalogViewMode>(
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
    ],
  );
}
