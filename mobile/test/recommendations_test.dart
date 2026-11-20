import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/recommendations.dart';

import 'catalog_test.dart' show signed;

/// Corridas indicadas no Início. Dados fictícios [FICTICIA].
void main() {
  final now = DateTime(2026, 11, 20);
  Map<String, dynamic> race(
    String id,
    String date, {
    String city = 'São Paulo',
    List<num> km = const [10],
    num? score,
    String status = 'upcoming',
  }) => {
    'id': id,
    'name': '[FICTICIA] Corrida $id',
    'date': date,
    'city': city,
    'state': 'SP',
    'status': status,
    'distances': [
      for (final k in km) {'id': '${k}k', 'kilometers': k},
    ],
    'runScore': ?(score == null ? null : {'value': score}),
  };

  test(
    'ordena pela distância que a pessoa corre, perto, logo e bem avaliada',
    () {
      final list = rankRecommendations(
        [
          race('longe', '2026-12-10', city: 'Presidente Prudente'),
          race('5k', '2026-12-10', km: [5]),
          race('10k', '2026-12-10'),
          race('10k-nota', '2026-12-10', score: 4.8),
          race('passada', '2026-11-01'),
          race('marcada', '2026-12-10'),
          race('arquivada', '2026-12-10', status: 'archived'),
        ],
        lat: -23.55,
        lon: -46.63,
        preferredKm: 10,
        exclude: {'marcada'},
        now: now,
      );
      final ids = [for (final r in list) r.edition['id']];
      expect(ids.first, '10k-nota');
      expect(ids.indexOf('10k'), lessThan(ids.indexOf('5k')));
      expect(ids, isNot(contains('longe'))); // a mais de 150 km
      expect(ids, isNot(contains('passada')));
      expect(ids, isNot(contains('marcada')));
      expect(ids, isNot(contains('arquivada')));
      expect(list.first.reasons, contains('10K, como você costuma correr'));
      expect(list.first.reasons, contains('Perto de você'));
    },
  );

  test('distância preferida: a mais corrida', () {
    expect(preferredDistanceKm([5, 10, 10, 21.1]), 10);
    expect(preferredDistanceKm([21.1, 21.0975]), 21.1);
    expect(preferredDistanceKm([]), isNull);
  });

  testWidgets('carrossel "Corridas para você" com o motivo de cada uma', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await signed(
      (uri, method, headers, body) async => const JsonReply(200, {}),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecommendedRaces(
            gateway: gateway,
            loader: (_) async => [
              Recommendation(race('A', '2026-12-10'), 5, const [
                '10K, como você costuma correr',
                'Perto de você',
              ]),
              Recommendation(race('B', '2026-12-20'), 3, const []),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Corridas para você'), findsOneWidget);
    expect(find.byKey(const Key('recommended-A')), findsOneWidget);
    expect(find.byKey(const Key('recommended-B')), findsOneWidget);
    expect(
      find.text('10K, como você costuma correr · Perto de você'),
      findsOneWidget,
    );
  });

  testWidgets('sem indicação, a seção não aparece', (tester) async {
    final gateway = await signed(
      (uri, method, headers, body) async => const JsonReply(200, {}),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecommendedRaces(gateway: gateway, loader: (_) async => []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recommended-races')), findsNothing);
  });
}
