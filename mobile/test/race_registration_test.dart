import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';

import 'catalog_test.dart' show entry, signed;

/// Cadastro da corrida igual em todas as telas: "Já corri" vai direto ao cadastro (sem a tela de informações),
/// corrida sem distância pede o km, e o Postar foto chega ao mesmo cadastro com a foto da publicação.
/// Dados fictícios [FICTICIA].
void main() {
  Future<(IdentityGateway, List<String>, List<Object?>)> setup({
    List<Map<String, dynamic>> distances = const [
      {'id': '5k', 'kilometers': 5},
      {'id': '10k', 'kilometers': 10},
    ],
    List<Map<String, dynamic>> mine = const [],
  }) async {
    final calls = <String>[];
    final bodies = <Object?>[];
    var current = [...distances];
    final edition = {
      ...entry('A'),
      'id': 'EA',
      'name': 'Corrida A [FICTICIA]',
      'status': 'upcoming',
      'date': '2026-12-01',
    };
    final gateway = await signed((uri, method, headers, body) async {
      calls.add('$method ${uri.path}');
      if (method == 'POST') bodies.add(body);
      if (uri.path == '/editions' && method == 'GET') {
        return JsonReply(200, {
          'items': [
            {...edition, 'distances': current},
          ],
        });
      }
      if (uri.path == '/editions/EA' && method == 'GET') {
        return JsonReply(200, {...edition, 'distances': current});
      }
      if (uri.path == '/editions/EA/distances' && method == 'POST') {
        current = [
          {'id': 'd21', 'kilometers': 21.1, 'informedBy': 'runner'},
        ];
        return JsonReply(200, {...edition, 'distances': current});
      }
      if (uri.path == '/me/participations') {
        return JsonReply(200, {'items': mine});
      }
      if (uri.path == '/participations' && method == 'POST') {
        final distance = (body as Map)['distanceId'];
        return JsonReply(201, {
          'id': 'P1',
          'editionId': 'EA',
          'distanceId': distance,
          'state': 'draft',
          'version': 1,
        });
      }
      return const JsonReply(200, {'items': []});
    });
    return (gateway, calls, bodies);
  }

  Future<void> openCatalog(WidgetTester tester, IdentityGateway gateway) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
  }

  testWidgets(
    '"Já corri" vai direto ao cadastro: escolhe a distância e abre o rascunho, sem a tela da corrida',
    (tester) async {
      final (gateway, calls, bodies) = await setup();
      await openCatalog(tester, gateway);
      await tester.tap(find.byKey(const Key('quick-ran-EA')));
      await tester.pumpAndSettle();
      expect(find.text('Qual distância você correu?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('distance-option-10k')));
      await tester.pumpAndSettle();
      expect(calls, contains('POST /participations'));
      expect((bodies.last as Map)['distanceId'], '10k');
      expect(find.byType(ParticipationDraftScreen), findsOneWidget);
      expect(find.byType(EditionScreen), findsNothing);
    },
  );

  testWidgets(
    'corrida sem km: pede a distância, envia como número e segue para o cadastro',
    (tester) async {
      final (gateway, calls, bodies) = await setup(distances: const []);
      await openCatalog(tester, gateway);
      await tester.tap(find.byKey(const Key('quick-ran-EA')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('add-distance-field')),
        '21,1',
      );
      await tester.tap(find.byKey(const Key('add-distance-confirm')));
      await tester.pumpAndSettle();
      final sent = bodies.firstWhere(
        (b) => b is Map && b.containsKey('kilometers'),
      );
      expect((sent as Map)['kilometers'], 21.1); // número, não texto
      expect(calls, contains('POST /participations'));
      expect(find.byType(ParticipationDraftScreen), findsOneWidget);
    },
  );

  testWidgets('km inválido avisa e não grava nada', (tester) async {
    final (gateway, calls, _) = await setup(distances: const []);
    await openCatalog(tester, gateway);
    await tester.tap(find.byKey(const Key('quick-ran-EA')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('add-distance-field')), 'abc');
    await tester.tap(find.byKey(const Key('add-distance-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Informe a distância em km'), findsOneWidget);
    expect(calls, isNot(contains('POST /editions/EA/distances')));
    expect(calls, isNot(contains('POST /participations')));
  });

  testWidgets(
    'Postar foto numa corrida já concluída: abre o mesmo cadastro (a medalha) com a foto da publicação',
    (tester) async {
      final (gateway, calls, _) = await setup(
        mine: const [
          {
            'id': 'P9',
            'editionId': 'EA',
            'distanceId': '10k',
            'state': 'completed',
            'version': 3,
          },
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => openRaceRegistration(
                context,
                gateway,
                {...entry('A'), 'id': 'EA'},
                postPhoto: const [0xff, 0xd8, 0xff, 0xd9],
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      final screen = tester.widget<ParticipationDraftScreen>(
        find.byType(ParticipationDraftScreen),
      );
      expect(screen.initial['id'], 'P9');
      expect(screen.medalMode, isTrue);
      expect(screen.initialPostPhoto, isNotNull);
      expect(calls, isNot(contains('POST /participations'))); // não cria outra
    },
  );
}
