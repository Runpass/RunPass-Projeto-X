import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/identity_gateway.dart';

Map<String, dynamic> post(String id, String authorId) => {
  'id': id,
  'author': {
    'id': authorId,
    'displayName': authorId == 'me' ? 'Eu' : 'Amiga',
    'username': authorId,
    'version': 1,
  },
  'participation': {
    'id': id,
    'editionId': 'E1',
    'distanceId': '10k',
    'state': 'completed',
    'version': 4,
  },
  'publishedAt': '2026-11-05T10:00:00Z',
  'commentCount': 0,
  'likeCount': 0,
  'likedByMe': false,
};

Future<IdentityGateway> gateway(List<String> calls) async {
  var removed = false;
  final g = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      if (uri.path == '/me') {
        return const JsonReply(200, {
          'id': 'me',
          'displayName': 'Eu',
          'username': 'me',
          'version': 2,
        });
      }
      if (uri.path == '/feed') {
        return JsonReply(200, {
          'items': [
            if (!removed) post('p-minha', 'me'),
            post('p-amiga', 'amiga'),
          ],
        });
      }
      if (method == 'DELETE' && uri.path.startsWith('/participations/')) {
        calls.add(
          '$method ${uri.path} ${uri.queryParameters['expectedVersion']}',
        );
        removed = true;
        return const JsonReply(202, {});
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await g.signIn('synthetic@example.test', 'synthetic');
  return g;
}

void main() {
  testWidgets('no início, os três pontinhos da minha publicação têm Editar e '
      'Remover; a de outra pessoa não tem menu', (tester) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(home: RunPassHomeScreen(gateway: await gateway(calls))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('post-menu-p-minha')), findsOneWidget);
    expect(find.byKey(const Key('post-menu-p-amiga')), findsNothing);
    await tester.tap(find.byKey(const Key('post-menu-p-minha')));
    await tester.pumpAndSettle();
    expect(find.text('Editar'), findsOneWidget);
    expect(find.text('Remover'), findsOneWidget);
  });

  testWidgets(
    'Remover pede confirmação, exclui a participação e some do início',
    (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: await gateway(calls))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-menu-p-minha')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-menu-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Remover publicação?'), findsOneWidget);
      // Cancelar não exclui nada.
      await tester.tap(find.byKey(const Key('post-remove-cancel')));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.byKey(const Key('post-menu-p-minha')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-menu-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-remove-confirm')));
      await tester.pumpAndSettle();
      expect(calls, ['DELETE /participations/p-minha 4']);
      expect(find.byKey(const Key('post-menu-p-minha')), findsNothing);
      expect(find.text('Publicação removida.'), findsOneWidget);
    },
  );
}
