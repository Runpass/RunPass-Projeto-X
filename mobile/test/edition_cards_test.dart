import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
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
              'city': 'Itu',
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
    // A data vai num selo sobre a foto; o local e as distâncias, embaixo, com ícone.
    expect(find.byKey(const Key('date-chip-EA')), findsOneWidget);
    expect(find.text('Amanhã'), findsOneWidget);
    expect(find.text('Itu, SP'), findsOneWidget);
    expect(find.byIcon(Icons.place_outlined), findsOneWidget);
    // O ícone de corrida aparece na linha das distâncias (e também na arte de tipo "rua").
    expect(find.byIcon(Icons.directions_run), findsWidgets);
    expect(find.text('Corrida A'), findsOneWidget);
    // A pílula da distância (a imagem ocupa a largura inteira do cartão e desenha a distância).
    expect(find.text('5K'), findsOneWidget);
    // Cidade sem foto: capa genérica, no mesmo padrão das fotos (imagem limpa, sem texto por cima).
    expect(find.byKey(const Key('race-art-photo')), findsOneWidget);
    expect(find.byKey(const Key('race-art-city')), findsNothing);
    expect(find.text('ITU · SP'), findsNothing);
  });

  test('tipo da prova pelo nome, para a arte padrão', () {
    expect(raceKind('Corrida Kids do Parque'), RaceKind.kids);
    expect(raceKind('Desafio Trilha da Serra'), RaceKind.trilha);
    expect(raceKind('Night Run Outubro Rosa'), RaceKind.noturna);
    expect(raceKind('Meia Maratona de São Paulo'), RaceKind.rua);
  });

  testWidgets(
    'miniatura sem foto: tipo e distância (ou sigla da cidade) em destaque',
    (tester) async {
      Future<void> art(Map<String, dynamic> edition) => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 76,
              height: 76,
              child: RaceArt(edition: edition),
            ),
          ),
        ),
      );
      await art({
        'id': 'a',
        'name': 'Trail da Serra',
        'city': 'Itu',
        'distances': [
          {'kilometers': 21.0975},
          {'kilometers': 5},
        ],
      });
      expect(find.byKey(const Key('race-art-trilha')), findsOneWidget);
      expect(find.text('21K'), findsOneWidget);
      await art({
        'id': 'b',
        'name': 'Corrida X',
        'city': 'Santos',
        'distances': [],
      });
      expect(find.byKey(const Key('race-art-rua')), findsOneWidget);
      expect(find.text('SAN'), findsOneWidget);
    },
  );

  testWidgets(
    'linha de "Quero correr": nome em duas linhas, data e local cabem sem estourar',
    (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final gateway = await signed(
        (uri, method, headers, body) async => const JsonReply(200, {}),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanRow(
              gateway: gateway,
              edition: {
                ...entry('A'),
                'id': 'EA',
                'name': 'Circuito das Estações de Corrida de Rua - Etapa Outono 2027',
                'date': '2027-03-14',
                'city': 'São Bernardo do Campo',
                'state': 'SP',
              },
              trailing: const Icon(Icons.favorite),
            ),
          ),
        ),
      );
      await tester.pump();
      // Sem "RenderFlex overflowed": o texto cabe na linha.
      expect(tester.takeException(), isNull);
      expect(find.text('14 de março de 2027'), findsOneWidget);
      expect(find.text('São Bernardo do Campo, SP'), findsOneWidget);
    },
  );
}
