import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/post_card.dart';
import 'package:runpass/tagged_people.dart';

Future<IdentityGateway> gateway() async {
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
      if (uri.path == '/profiles/suggestions' || uri.path == '/profiles') {
        return const JsonReply(200, {
          'items': [
            {'id': 'u1', 'displayName': '[FICTICIA] Ana', 'username': 'ana'},
            {'id': 'u2', 'displayName': '[FICTICIA] Beto', 'username': 'beto'},
          ],
        });
      }
      return const JsonReply(404, {'code': 'NOT_FOUND'});
    },
  );
  await g.signIn('synthetic@example.test', 'synthetic');
  return g;
}

void main() {
  testWidgets(
    'link Marcados ao lado do comentário abre o pop-up com os perfis',
    (tester) async {
      final g = await gateway();
      final entry = entryFromPost(
        {
          'id': 'p1',
          'author': {'id': 'x', 'displayName': 'Autora', 'username': 'autora'},
          'participation': {
            'id': 'p1',
            'editionId': 'E1',
            'state': 'completed',
          },
          'publishedAt': '2026-11-01T10:00:00Z',
          'comment': 'Foi lindo',
          'tagged': [
            {'id': 'u1', 'displayName': '[FICTICIA] Ana', 'username': 'ana'},
            {'id': 'u2', 'displayName': '[FICTICIA] Beto', 'username': 'beto'},
          ],
        },
        null,
        'me',
      );
      expect(entry.tagged.length, 2);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [PostCard(gateway: g, entry: entry)],
            ),
          ),
        ),
      );
      expect(find.text('Foi lindo'), findsOneWidget);
      expect(find.byKey(const Key('post-tagged-p1')), findsOneWidget);
      // Fica na linha de baixo, à direita do ícone de comentários.
      expect(
        tester.getTopLeft(find.byKey(const Key('post-tagged-p1'))).dy,
        greaterThan(tester.getTopLeft(find.text('Foi lindo')).dy),
      );
      await tester.ensureVisible(find.byKey(const Key('post-tagged-p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-tagged-p1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tagged-dialog')), findsOneWidget);
      expect(find.text('@ana'), findsOneWidget);
      expect(find.text('@beto'), findsOneWidget);
    },
  );

  testWidgets('sem marcados não aparece o link', (tester) async {
    final g = await gateway();
    final entry = entryFromPost(
      {
        'id': 'p2',
        'author': {'id': 'x', 'displayName': 'Autora', 'username': 'autora'},
        'participation': {'id': 'p2', 'editionId': 'E1', 'state': 'completed'},
        'publishedAt': '2026-11-01T10:00:00Z',
        'comment': 'Sem marcação',
      },
      null,
      'me',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [PostCard(gateway: g, entry: entry)],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('post-tagged-p2')), findsNothing);
  });

  testWidgets('escolher pessoas: marca, mostra o chip e devolve os perfis', (
    tester,
  ) async {
    final g = await gateway();
    List<Map<String, dynamic>>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await pickTaggedPeople(context, g, const []),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    // Ao abrir, ninguém é sugerido: só aparecem pessoas depois de digitar o nome.
    expect(find.byKey(const Key('tag-option-u2')), findsNothing);
    expect(find.byKey(const Key('tag-empty')), findsOneWidget);
    expect(find.textContaining('Digite o nome'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('tag-search')), 'be');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tag-empty')), findsNothing);
    await tester.tap(find.byKey(const Key('tag-option-u2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tag-chip-u2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tag-done')));
    await tester.pumpAndSettle();
    expect(result?.map((p) => p['id']), ['u2']);
  });

  testWidgets(
    'não chama a lista de sugestões e só busca com 2 letras ou mais',
    (tester) async {
      final paths = <String>[];
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
          paths.add('${uri.path}?${uri.query}');
          return const JsonReply(200, {'items': []});
        },
      );
      await g.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickTaggedPeople(context, g, const []),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tag-search')), 'b');
      await tester.pumpAndSettle();
      expect(paths, isEmpty); // nem ao abrir, nem com 1 letra
      await tester.enterText(find.byKey(const Key('tag-search')), 'be');
      await tester.pumpAndSettle();
      expect(paths.single, startsWith('/profiles?'));
      expect(paths.any((p) => p.contains('suggestions')), isFalse);
    },
  );
}
