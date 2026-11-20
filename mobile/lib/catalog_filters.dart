import 'package:flutter/material.dart';

import 'br_locations.dart';
import 'home_screen.dart' show haversineKm, nearbyCityRadiusKm;
import 'runpass_theme.dart';

/// Pílula de filtro da tela Corridas (como "Esporte, Datas, Distância, Localização"): borda arredondada e fina,
/// ícone opcional e o rótulo. Ativa, ganha a cor da marca e o valor escolhido; o × tira o filtro.
class FilterPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool active;
  final VoidCallback onTap;

  /// Tira o filtro; só aparece com a pílula ativa.
  final VoidCallback? onClear;
  const FilterPill({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.active = false,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final color = active
        ? runPassOrange
        : Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active
            ? runPassOrange.withValues(alpha: 0.12)
            : Colors.transparent,
        shape: StadiumBorder(
          side: BorderSide(
            color: active
                ? runPassOrange
                : context.muted.withValues(alpha: 0.5),
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
                if (active && onClear != null) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: onClear,
                    customBorder: const CircleBorder(),
                    child: Icon(Icons.close_rounded, size: 18, color: color),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Onde a corrida acontece: a coordenada da própria edição ou, quando ela não tem, o centro da cidade (tabela
/// por UF + cidade). Nulo se não der para saber.
({double lat, double lon})? raceCoordinate(Map<String, dynamic> edition) {
  final lat = (edition['latitude'] as num?)?.toDouble();
  final lon = (edition['longitude'] as num?)?.toDouble();
  if (lat != null && lon != null) return (lat: lat, lon: lon);
  final state = '${edition['state'] ?? ''}'.trim();
  final city = '${edition['city'] ?? ''}'.trim();
  final center = brCityCoordinates['$state|$city'];
  return center == null ? null : (lat: center.lat, lon: center.lon);
}

/// A corrida está a até [km] de quem está em ([lat], [lon])? Sem coordenada da corrida, não entra.
bool withinRadiusOf(
  Map<String, dynamic> edition,
  double lat,
  double lon, [
  double km = nearbyCityRadiusKm,
]) {
  final at = raceCoordinate(edition);
  return at != null && haversineKm(lat, lon, at.lat, at.lon) <= km;
}
