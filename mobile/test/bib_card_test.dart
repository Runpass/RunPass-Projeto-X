import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/bib_card.dart';
import 'package:runpass/my_races.dart';

/// Cartão do número de peito. Dados fictícios [FICTICIA].
void main() {
  test('distância e colocação no jeito do número de peito', () {
    expect(bibDistanceLabel(42.195), '42K');
    expect(bibDistanceLabel(21.0975), '21K');
    expect(bibDistanceLabel(10), '10K');
    expect(bibDistanceLabel(7.5), '7,5K');
    expect(bibDistanceLabel(null), isNull);
    expect(bibPlacementLabel(12), '12º LUGAR');
    expect(bibPlacementLabel(null), isNull);
    expect(bibNumberOf({'bibNumber': ' 6728 '}), '6728');
    expect(bibNumberOf({'bibNumber': ''}), isNull);
    expect(bibNumberOf({}), isNull);
  });

  RaceRecord race(Map<String, dynamic> participation) => RaceRecord(
    {'id': 'p1', 'editionId': 'E1', 'distanceId': '42k', ...participation},
    {
      'id': 'E1',
      'name': '[FICTICIA] Desafio da Serra',
      'date': '2026-05-10',
      'city': 'São Paulo',
      'state': 'SP',
      'distances': [
        {'id': '42k', 'kilometers': 42.195},
      ],
    },
  );

  test('só corrida com número de peito ganha cartão', () {
    expect(BibCard.of(race({})), isNull);
    final card = BibCard.of(race({'bibNumber': '6728', 'placement': 12}))!;
    expect(card.bib, '6728');
    expect(card.distance, '42K');
    expect(card.placement, '12º LUGAR');
    expect(BibCard.of(race({'bibNumber': '15'}))!.placement, isNull);
  });

  testWidgets(
    'o cartão mostra o número, a distância, a corrida e a colocação',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 340,
              child: BibCard.of(race({'bibNumber': '6728', 'placement': 12})),
            ),
          ),
        ),
      );
      expect(find.text('6728'), findsOneWidget);
      expect(find.text('42K'), findsOneWidget);
      expect(find.text('12º LUGAR'), findsOneWidget);
      expect(find.text('[FICTICIA] DESAFIO DA SERRA'), findsOneWidget);
      expect(tester.takeException(), isNull); // sem estouro de layout
    },
  );
}
