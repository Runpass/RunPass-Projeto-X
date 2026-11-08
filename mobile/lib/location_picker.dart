import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'br_locations.dart';
import 'runpass_theme.dart';

/// "SP - Taboão da Serra", ou nulo se o perfil ainda não tem estado/cidade salvos.
String? brLocationLabel(Map profile) {
  final uf = profile['state'] as String?;
  final city = profile['city'] as String?;
  if (uf == null || city == null) return null;
  return '$uf - $city';
}

/// Corpo do PATCH /me para salvar o estado/cidade escolhidos no seletor, com a latitude e
/// longitude do centroide quando a cidade tem coordenada conhecida (ver brCityCoordinates) —
/// usadas só pelo raio de proximidade do filtro "Minha Cidade". Sem coordenada, salva só
/// estado/cidade; o filtro cai para comparar apenas o nome da cidade nesse caso.
Map<String, dynamic> brLocationPatch(
  String uf,
  String city,
  double? lat,
  double? lon,
) => {'state': uf, 'city': city, 'latitude': ?lat, 'longitude': ?lon};

/// Seletor de Estado (UF) e cidade por rolagem — mesmo padrão visual da data de nascimento,
/// sem campo de digitação (lista fechada do IBGE, evita erro de digitação). Trocar o estado
/// reinicia a coluna de cidade para a primeira da lista nova.
Future<(String uf, String city, double? lat, double? lon)?> pickBrLocation(
  BuildContext context, {
  String? initialUf,
  String? initialCity,
}) async {
  var ufIndex = 0;
  if (initialUf != null) {
    final found = brStates.indexWhere((s) => s.uf == initialUf);
    if (found >= 0) ufIndex = found;
  }
  var cities = brCitiesByState[brStates[ufIndex].uf] ?? const <String>[];
  var cityIndex = initialCity == null ? 0 : cities.indexOf(initialCity);
  if (cityIndex < 0) cityIndex = 0;

  final ufController = FixedExtentScrollController(initialItem: ufIndex);
  var cityController = FixedExtentScrollController(initialItem: cityIndex);

  Widget wheelColumn({
    required String label,
    required Key? key,
    required FixedExtentScrollController controller,
    required int itemCount,
    required Widget Function(BuildContext, int) itemBuilder,
    required ValueChanged<int> onChanged,
  }) => Expanded(
    child: Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: context.muted,
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: CupertinoPicker.builder(
            key: key,
            scrollController: controller,
            itemExtent: 40,
            onSelectedItemChanged: onChanged,
            childCount: itemCount,
            selectionOverlay: Container(
              decoration: BoxDecoration(
                color: runPassOrange.withValues(alpha: .08),
                border: const Border.symmetric(
                  horizontal: BorderSide(color: runPassOrange, width: 1.2),
                ),
              ),
            ),
            itemBuilder: itemBuilder,
          ),
        ),
      ],
    ),
  );

  Widget cell(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: context.isDark ? Colors.white : runPassNavy,
        ),
      ),
    ),
  );

  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(sheetContext).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: sheetContext.track,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Estado e cidade',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: sheetContext.isDark ? Colors.white : runPassNavy,
                    ),
                  ),
                  TextButton(
                    key: const Key('location-done'),
                    onPressed: () => Navigator.pop(sheetContext, true),
                    child: const Text('Concluído'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 210,
                child: Row(
                  children: [
                    wheelColumn(
                      label: 'Estado',
                      key: null,
                      controller: ufController,
                      itemCount: brStates.length,
                      itemBuilder: (_, i) => cell(brStates[i].name),
                      onChanged: (i) => setSheetState(() {
                        ufIndex = i;
                        cities =
                            brCitiesByState[brStates[ufIndex].uf] ??
                            const <String>[];
                        cityIndex = 0;
                        cityController.dispose();
                        cityController = FixedExtentScrollController(
                          initialItem: 0,
                        );
                      }),
                    ),
                    wheelColumn(
                      label: 'Cidade',
                      // Troca de UF muda o total de itens: refaz o picker em vez de reaproveitar
                      // o controlador antigo, que poderia apontar para um indice fora da faixa.
                      key: ValueKey(ufIndex),
                      controller: cityController,
                      itemCount: cities.length,
                      itemBuilder: (_, i) => cell(cities[i]),
                      onChanged: (i) => cityIndex = i,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  ufController.dispose();
  cityController.dispose();
  if (confirmed != true || !context.mounted) return null;
  final uf = brStates[ufIndex].uf;
  final city = cities[cityIndex];
  final coord = brCityCoordinates['$uf|$city'];
  return (uf, city, coord?.lat, coord?.lon);
}
