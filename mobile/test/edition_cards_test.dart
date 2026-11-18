import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/edition_cards.dart';
import 'package:runpass/identity_gateway.dart';

import 'catalog_test.dart' show entry, signed;

void main() {
  // Quarta-feira, 18/11/2026.
  final now = DateTime(2026, 11, 18, 10);

  test('data relativa para ler de relance', () {
    expect(relativeDay('2026-11-18', now: now), 'Hoje');
    expect(relativeDay('2026-11-19', now: now), 'Amanhã');
    expect(relativeDay('2026-11-21', now: now), 'Sáb, 21 nov');
    expect(relativeDay('2026-12-06', now: now), '6 dez');
    expect(relativeDay('2027-01-10', now: now), '10 jan 2027');
  });

  test('seções da lista por período', () {
    expect(periodOf('2026-11-18', now: now), 'Hoje');
    expect(periodOf('2026-11-19', now: now), 'Amanhã');
    expect(periodOf('2026-11-21', now: now), 'Este fim de semana');
    expect(periodOf('2026-11-22', now: now), 'Este fim de semana');
    expect(periodOf('2026-11-24', now: now), 'Próximos dias');
    expect(periodOf('2026-12-20', now: now), 'Mais adiante');
    expect(periodOf('2026-11-10', now: now), 'Já aconteceram');
  });

  test('distâncias em pílulas, com meia e maratona arredondadas', () {
    expect(
      distanceChips({
        'distances': [
          {'kilometers': 21.0975},
          {'kilometers': 5},
          {'kilometers': 42.195},
          {'kilometers': 7.5},
        ],
      }),
      ['5K', '7.5K', '21K', '42K'],
    );
    expect(distanceChips({'distances': []}), isEmpty);
  });

  testWidgets('cartão compacto mostra quando, onde, nome e distâncias', (
    tester,
  ) async {
    final gateway = await signed(
      (uri, method, headers, body) async => const JsonReply(200, {}),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditionCompactCard(
            gateway: gateway,
            now: now,
            edition: {
              ...entry('A'),
              'id': 'EA',
              'date': '2026-11-19',
              'city': 'Santos',
              'state': 'SP',
              'distances': [
                {'id': '5k', 'kilometers': 5},
              ],
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Amanhã · Santos/SP'), findsOneWidget);
    expect(find.text('Corrida A'), findsOneWidget);
    expect(find.text('5K'), findsOneWidget);
  });
}
