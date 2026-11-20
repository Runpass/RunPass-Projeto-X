import 'package:flutter/material.dart';

import 'br_locations.dart' show brCityCoordinates;
import 'catalog_filters.dart' show raceCoordinate;
import 'catalog_screen.dart'
    show CatalogScreen, EditionScreen, distanceLabel, loadMyEditions;
import 'city_photos.dart' show chooseDistinctCovers;
import 'edition_cards.dart' show EditionCompactCard;
import 'home_screen.dart' show haversineKm;
import 'identity_gateway.dart';
import 'my_races.dart' show loadMyRaces;
import 'runpass_theme.dart';

/// Corrida indicada para a pessoa, com os motivos (aparecem no cartão).
class Recommendation {
  final Map<String, dynamic> edition;
  final double score;
  final List<String> reasons;
  const Recommendation(this.edition, this.score, this.reasons);
}

/// Até onde procurar corridas para indicar (km da cidade do perfil) e por quanto tempo à frente.
const recommendationRadiusKm = 150.0;
const recommendationDays = 120;

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Ordena as corridas candidatas para a pessoa. Pontos: a distância que ela costuma correr, perto de casa,
/// acontecendo logo e bem avaliada. Deixa de fora as que ela já marcou ou correu ([exclude]) e as
/// arquivadas. Devolve as [limit] melhores, com os motivos em texto curto.
List<Recommendation> rankRecommendations(
  List<Map<String, dynamic>> candidates, {
  double? lat,
  double? lon,
  double? preferredKm,
  Set<String> exclude = const {},
  DateTime? now,
  int limit = 10,
}) {
  final today = now ?? DateTime.now();
  final day = DateTime(today.year, today.month, today.day);
  final out = <Recommendation>[];
  for (final edition in candidates) {
    final id = edition['id'];
    if (id is! String || exclude.contains(id)) continue;
    if (edition['status'] == 'archived') continue;
    final date = DateTime.tryParse('${edition['date'] ?? ''}');
    if (date == null || date.isBefore(day)) continue;
    var score = 0.0;
    final reasons = <String>[];
    // Distância: a que a pessoa mais corre.
    final kms = [
      for (final d in (edition['distances'] as List? ?? const []))
        if (d is Map && d['kilometers'] is num)
          (d['kilometers'] as num).toDouble(),
    ];
    if (preferredKm != null && kms.any((km) => (km - preferredKm).abs() <= 1)) {
      score += 3;
      reasons.add('${distanceLabel(preferredKm)}, como você costuma correr');
    }
    // Perto de casa.
    if (lat != null && lon != null) {
      final at = raceCoordinate(edition);
      if (at != null) {
        final km = haversineKm(lat, lon, at.lat, at.lon);
        if (km > recommendationRadiusKm) continue;
        if (km <= 30) {
          score += 2;
          reasons.add('Perto de você');
        } else if (km <= 100) {
          score += 1;
          reasons.add('A ${km.round()} km');
        }
      }
    }
    // Logo: dá tempo de se inscrever e treinar (entre 1 semana e 2 meses vale mais).
    final days = date.difference(day).inDays;
    if (days >= 7 && days <= 60) {
      score += 1;
      reasons.add(
        days < 14 ? 'Daqui a $days dias' : 'Em ${(days / 7).round()} semanas',
      );
    } else if (days < 7) {
      score += 0.5;
    }
    // Bem avaliada pelos corredores.
    final raw = (edition['runScore'] as Map?)?['value'];
    final rating = raw is num
        ? raw.toDouble()
        : double.tryParse('${raw ?? ''}');
    if (rating != null && rating >= 4) {
      score += rating - 3;
      reasons.add('Nota ${rating.toStringAsFixed(1).replaceAll('.', ',')}');
    }
    out.add(Recommendation(edition, score, reasons));
  }
  out.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return '${a.edition['date']}'.compareTo('${b.edition['date']}');
  });
  return out.take(limit).toList();
}

/// A distância que a pessoa mais correu (arredondada), ou nula sem histórico.
double? preferredDistanceKm(Iterable<double> ran) {
  final counts = <double, int>{};
  for (final km in ran) {
    final key = km >= 20 ? (km * 10).round() / 10 : km.roundToDouble();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
      .first
      .key;
}

/// Busca as candidatas (estado do perfil, próximos [recommendationDays] dias) e ordena para a pessoa.
/// Qualquer falha devolve lista vazia: é uma ajuda, nunca derruba o Início.
Future<List<Recommendation>> loadRecommendations(
  IdentityGateway gateway,
) async {
  try {
    final me = await gateway.request('/me');
    final state = '${me['state'] ?? ''}'.trim();
    final city = '${me['city'] ?? ''}'.trim();
    final center = brCityCoordinates['$state|$city'];
    final lat = (me['latitude'] as num?)?.toDouble() ?? center?.lat;
    final lon = (me['longitude'] as num?)?.toDouble() ?? center?.lon;
    final today = DateTime.now();
    final page = await gateway.request(
      '/editions',
      query: {
        if (state.isNotEmpty) 'state': state,
        'dateFrom': _iso(today),
        'dateTo': _iso(today.add(const Duration(days: recommendationDays))),
        'limit': '100',
      },
    );
    final candidates = [
      for (final item in (page['items'] as List? ?? const []))
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    final mine = await loadMyEditions(gateway);
    final exclude = {...mine.keys};
    try {
      final plans = await gateway.request('/me/race-plans');
      for (final p in (plans['items'] as List? ?? const [])) {
        if (p is Map && p['editionId'] is String) {
          exclude.add(p['editionId'] as String);
        }
      }
    } on Exception {
      // Sem a agenda: indica mesmo assim.
    }
    final ran = [
      for (final race in await loadMyRaces(gateway))
        if (race.kilometers != null) race.kilometers!,
    ];
    return rankRecommendations(
      candidates,
      lat: lat,
      lon: lon,
      preferredKm: preferredDistanceKm(ran),
      exclude: exclude,
    );
  } on Exception {
    return const [];
  }
}

/// "Corridas para você" no Início: carrossel com as corridas indicadas (o mesmo cartão da lista de
/// corridas, todos do mesmo tamanho) e o motivo de cada uma. Sem indicação, não aparece.
class RecommendedRaces extends StatefulWidget {
  final IdentityGateway gateway;
  final Future<List<Recommendation>> Function(IdentityGateway gateway) loader;
  const RecommendedRaces({
    super.key,
    required this.gateway,
    this.loader = loadRecommendations,
  });

  @override
  State<RecommendedRaces> createState() => _RecommendedRacesState();
}

class _RecommendedRacesState extends State<RecommendedRaces> {
  late Future<List<Recommendation>> items = widget.loader(widget.gateway);

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Recommendation>>(
    future: items,
    builder: (context, snapshot) {
      final list = snapshot.data ?? const <Recommendation>[];
      if (list.isEmpty) return const SizedBox.shrink();
      chooseDistinctCovers([for (final r in list) r.edition]);
      final width = (MediaQuery.sizeOf(context).width * .78).clamp(
        240.0,
        340.0,
      );
      return Padding(
        key: const Key('recommended-races'),
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Corridas para você',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                  ),
                ),
                TextButton(
                  key: const Key('recommended-all'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CatalogScreen(gateway: widget.gateway),
                    ),
                  ),
                  child: const Text('Ver todas'),
                ),
              ],
            ),
            Text(
              'Pela sua cidade, pelas distâncias que você corre e pelas datas.',
              style: TextStyle(color: context.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final r in list)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: SizedBox(
                          width: width,
                          child: EditionCompactCard(
                            key: Key('recommended-${r.edition['id']}'),
                            gateway: widget.gateway,
                            edition: r.edition,
                            uniform: true,
                            rating: r.reasons.isEmpty
                                ? null
                                : r.reasons.take(2).join(' · '),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => EditionScreen(
                                  gateway: widget.gateway,
                                  editionId: r.edition['id'] as String,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// "Pra você" no Início: as corridas indicadas em lista (o mesmo cartão da lista de corridas), cada uma com o
/// motivo. Sem indicação, um convite para completar o perfil e registrar corridas.
class RecommendedRacesList extends StatefulWidget {
  final IdentityGateway gateway;
  final Future<List<Recommendation>> Function(IdentityGateway gateway) loader;
  const RecommendedRacesList({
    super.key,
    required this.gateway,
    this.loader = loadRecommendations,
  });

  @override
  State<RecommendedRacesList> createState() => _RecommendedRacesListState();
}

class _RecommendedRacesListState extends State<RecommendedRacesList> {
  late Future<List<Recommendation>> items = widget.loader(widget.gateway);

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Recommendation>>(
    future: items,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      final list = snapshot.data ?? const <Recommendation>[];
      if (list.isEmpty) {
        return Padding(
          key: const Key('recommended-empty'),
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'Ainda não temos corridas para indicar. Confira a cidade no seu perfil e registre as '
            'corridas que você já fez: as indicações usam a sua cidade e as distâncias que você corre.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.muted),
          ),
        );
      }
      chooseDistinctCovers([for (final r in list) r.edition]);
      return Column(
        key: const Key('recommended-races'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Corridas pra você',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          Text(
            'Pela sua cidade, pelas distâncias que você corre e pelas datas.',
            style: TextStyle(color: context.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          for (final r in list)
            EditionCompactCard(
              key: Key('recommended-${r.edition['id']}'),
              gateway: widget.gateway,
              edition: r.edition,
              rating: r.reasons.isEmpty ? null : r.reasons.take(2).join(' · '),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => EditionScreen(
                    gateway: widget.gateway,
                    editionId: r.edition['id'] as String,
                  ),
                ),
              ),
            ),
          Align(
            child: TextButton(
              key: const Key('recommended-all'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CatalogScreen(gateway: widget.gateway),
                ),
              ),
              child: const Text('Ver todas as corridas'),
            ),
          ),
        ],
      );
    },
  );
}
