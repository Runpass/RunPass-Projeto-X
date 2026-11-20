import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/pending_participation.dart';

// Dados [FICTICIA]. A avaliação é opcional: dá para concluir sem ela e avaliar depois (as 8 notas ou nenhuma).

class Calls {
  final bodies = <String, Map<String, dynamic>>{};
  final paths = <String>[];
}

Future<IdentityGateway> gateway(
  Calls calls, {
  bool reviewMissing = true,
}) async {
  final g = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    sleeper: (_) async {},
    byteTransport: (uri, method, headers, bytes) async => 200,
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      calls.paths.add('$method ${uri.path}');
      if (body != null) {
        calls.bodies['$method ${uri.path}'] = Map<String, dynamic>.from(body);
      }
      if (uri.path == '/editions/A') {
        return const JsonReply(200, {
          'id': 'A',
          'name': '[FICTICIA] Corrida',
          'date': '2000-01-01',
          'city': 'São Paulo',
          'state': 'SP',
          'status': 'past',
          'version': 1,
          'distances': [
            {'id': '10k', 'kilometers': 10},
          ],
        });
      }
      if (uri.path == '/uploads') {
        return const JsonReply(201, {
          'uploadId': 'u1',
          'uploadUrl': 'https://private.example/u1',
          'uploadMethod': 'PUT',
          'uploadHeaders': {'Content-Type': 'image/jpeg'},
        });
      }
      if (uri.path.endsWith('/finalize')) {
        return const JsonReply(200, {
          'uploadId': 'u1',
          'state': 'valid',
          'imageReference': 'img-valid',
        });
      }
      if (uri.path == '/participations/d1/complete') {
        return const JsonReply(200, {
          'id': 'd1',
          'editionId': 'A',
          'distanceId': '10k',
          'state': 'completed',
          'version': 2,
        });
      }
      if (uri.path == '/participations/done-1/review') {
        if (method == 'GET') {
          return reviewMissing
              ? const JsonReply(404, {'code': 'REVIEW_NOT_FOUND'})
              : JsonReply(200, {
                  'participationId': 'done-1',
                  'version': 1,
                  'ratings': <String, dynamic>{
                    for (final k in [
                      'organization',
                      'course',
                      'kit',
                      'medal',
                      'hydration',
                      'facilities',
                      'safety',
                      'valueForMoney',
                    ])
                      k: 5,
                  },
                  'moderationState': 'valid',
                });
        }
        return JsonReply(200, {
          ...?(body as Map?)?.cast<String, dynamic>(),
          'participationId': 'done-1',
          'version': 1,
          'moderationState': 'valid',
        });
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await g.signIn('synthetic@example.test', 'synthetic');
  return g;
}

Future<void> tapKey(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  final list = find.byType(Scrollable).first;
  await tester.scrollUntilVisible(finder, 200, scrollable: list);
  final area = tester.getRect(list);
  for (var i = 0; i < 30; i++) {
    final y = tester.getCenter(finder).dy;
    if (y > area.top + 24 && y < area.bottom - 24) break;
    await tester.drag(list, Offset(0, y <= area.top + 24 ? 150 : -150));
    await tester.pump();
  }
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(draftFormCache.clear);

  testWidgets(
    'concluir sem avaliar: não envia notas e avisa que dá para avaliar depois',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = Calls();
      final g = await gateway(calls);
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: g,
            initial: const {
              'id': 'd1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'draft',
              'version': 1,
            },
            photoSelector: () async => [0xff, 0xd8, 0xff, 0xd9],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Selecionar foto'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      final finish = find.text('Concluir participação');
      await tester.ensureVisible(finish);
      await tester.tap(find.text('Concluir participação'));
      await tester.pumpAndSettle();
      final body = calls.bodies['POST /participations/d1/complete']!;
      expect(body.containsKey('ratings'), isFalse);
      expect(body.containsKey('comment'), isFalse);
      expect(body['medalImageReference'], 'img-valid');
      expect(find.textContaining('avaliar depois'), findsOneWidget);
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
    },
  );

  testWidgets(
    'participação concluída sem avaliação: avalia depois na própria tela (PUT com versão 0)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = Calls();
      final g = await gateway(calls);
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: g,
            initial: const {
              'id': 'done-1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'completed',
              'version': 2,
              'showTime': true,
              'showPlacement': true,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('no-review-hint')),
        300,
        scrollable: list,
      );
      expect(find.byKey(const Key('no-review-hint')), findsOneWidget);
      await tapKey(tester, const Key('same-rating-4'));
      await tapKey(tester, const Key('save-data'));
      final put = calls.bodies['PUT /participations/done-1/review']!;
      expect(put['expectedVersion'], 0); // cria a avaliação
      expect((put['ratings'] as Map).length, 8);
      expect((put['ratings'] as Map).values.every((v) => v == 4), isTrue);
    },
  );

  testWidgets(
    'concluída sem avaliação e sem notas dadas: Salvar dados não cria avaliação',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = Calls();
      final g = await gateway(calls);
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: g,
            initial: const {
              'id': 'done-1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'completed',
              'version': 2,
              'showTime': true,
              'showPlacement': true,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('save-data'));
      expect(
        calls.paths.any((p) => p.startsWith('PUT') && p.endsWith('/review')),
        isFalse,
      );
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
    },
  );

  testWidgets(
    'pedido de corrida nova: sem notas envia sem avaliação; notas pela metade não enviam',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Map<String, dynamic>? sent;
      final g = await gateway(Calls());
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  sent = await Navigator.of(context).push<Map<String, dynamic>>(
                    MaterialPageRoute(
                      builder: (_) => PendingParticipationScreen(
                        gateway: g,
                        raceName: 'Corrida Nova',
                      ),
                    ),
                  ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      // Notas pela metade: não envia e avisa.
      final first = find.byWidgetPredicate(
        (w) => w is RatingInput && w.label == 'Kit',
      );
      tester.widget<RatingInput>(first).onChanged!(3);
      await tester.pump();
      await tapKey(tester, const Key('pending-save'));
      expect(sent, isNull);
      expect(find.textContaining('8 critérios'), findsWidgets);
      // Sem nenhuma nota: envia sem avaliação.
      tester.widget<RatingInput>(first).onChanged!(0);
      await tester.pump();
      await tapKey(tester, const Key('pending-save'));
      expect(sent, isNotNull);
      expect(sent!.containsKey('ratings'), isFalse);
      expect(sent!['publishToFeed'], isFalse);
    },
  );
}
