import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';

// Dados [FICTICIA]. A foto da medalha pode ser a foto do post (enviada como cópia), e quem não publicou ao cadastrar
// publica depois pela tela da medalha; quem já publicou edita a publicação.

const jpeg = [0xff, 0xd8, 0xff, 0xd9];

class Log {
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  var uploads = 0;
}

Future<IdentityGateway> gateway(Log log) async {
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
      log.calls.add('$method ${uri.path}');
      if (body != null) {
        log.bodies['$method ${uri.path}'] = Map<String, dynamic>.from(body);
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
        log.uploads++;
        return JsonReply(201, {
          'uploadId': 'u${log.uploads}',
          'uploadUrl': 'https://private.example/u${log.uploads}',
          'uploadMethod': 'PUT',
          'uploadHeaders': {'Content-Type': 'image/jpeg'},
        });
      }
      if (uri.path.endsWith('/finalize')) {
        final id = uri.path.split('/')[2];
        return JsonReply(200, {
          'uploadId': id,
          'state': 'valid',
          // Cada envio vira uma imagem própria (referência diferente), mesmo com os mesmos bytes.
          'imageReference': 'img_${id.padRight(64, '0')}',
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
      if (uri.path == '/participations/m1/image') {
        return const JsonReply(200, {
          'url': 'https://private.example/medal.jpg',
        });
      }
      if (uri.path == '/participations/m1/publish') {
        return JsonReply(200, {
          'id': 'm1',
          'editionId': 'A',
          'distanceId': '10k',
          'state': 'completed',
          'version': 4,
          'publishToFeed': true,
          'postImageReference': log
              .bodies['POST /participations/m1/publish']!['postImageReference'],
        });
      }
      if (uri.path == '/posts/m1') {
        return const JsonReply(200, {'id': 'm1', 'tagged': []});
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
    'cadastro: ao marcar "Publicar", a foto da medalha já vira a foto do post (cópia própria)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final log = Log();
      final g = await gateway(log);
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
            photoSelector: () async => jpeg,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Selecionar foto'));
      await tester.pumpAndSettle();
      expect(log.uploads, 1); // a foto da medalha
      await tapKey(tester, const Key('publish-to-feed'));
      // Sem escolher nada: a medalha foi enviada de novo como foto própria do post.
      expect(log.uploads, 2);
      expect(find.byKey(const Key('post-photo-ok')), findsOneWidget);
      expect(find.byKey(const Key('use-medal-for-post')), findsOneWidget);
    },
  );

  testWidgets(
    'medalha concluída sem publicação: "Publicar no feed" usa a foto da medalha e publica depois da prévia',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final log = Log();
      final g = await gateway(log);
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: g,
            medalMode: true,
            medalPhotoFetcher: (_) async => jpeg,
            initial: const {
              'id': 'm1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'completed',
              'version': 3,
              'publishToFeed': false,
              'medalImageReference': 'img-medal',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-publication')), findsNothing);
      await tapKey(tester, const Key('publish-from-medal'));
      expect(log.uploads, 1); // a foto da medalha enviada como cópia do post
      expect(
        find.text(
          'A foto da medalha será a foto da publicação. Você pode trocar por outra.',
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('post-text-field')),
        'Minha medalha',
      );
      await tapKey(tester, const Key('publish-now'));
      expect(
        find.byKey(const Key('post-preview')),
        findsOneWidget,
      ); // prévia antes de publicar
      await tester.tap(find.byKey(const Key('post-preview-confirm')));
      await tester.pumpAndSettle();
      final body = log.bodies['POST /participations/m1/publish']!;
      expect(body['expectedVersion'], 3);
      expect(body['postText'], 'Minha medalha');
      expect((body['postImageReference'] as String).startsWith('img_'), isTrue);
      // Depois de publicar, o botão vira "Editar publicação no feed".
      expect(find.byKey(const Key('edit-publication')), findsOneWidget);
      expect(find.byKey(const Key('publish-from-medal')), findsNothing);
    },
  );

  testWidgets(
    'medalha já publicada: "Editar publicação no feed" abre a edição do post',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final log = Log();
      final g = await gateway(log);
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: g,
            medalMode: true,
            initial: const {
              'id': 'm1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'completed',
              'version': 3,
              'publishToFeed': true,
              'postImageReference': 'img_post',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('publish-from-medal')), findsNothing);
      await tapKey(tester, const Key('edit-publication'));
      expect(log.calls, contains('GET /posts/m1'));
      expect(
        find.byKey(const Key('replace-post-photo')),
        findsOneWidget,
      ); // a edição do post
      expect(find.byKey(const Key('post-text-edit')), findsOneWidget);
    },
  );
}
