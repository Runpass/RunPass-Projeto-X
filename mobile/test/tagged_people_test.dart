import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/friends.dart' show ProfileAvatar;
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
      // Ordem do cartão: título, texto da publicação, foto e, na linha das ações abaixo da foto, os marcados.
      final title = tester.getTopLeft(find.byKey(const Key('post-race-p1'))).dy;
      final text = tester.getTopLeft(find.text('Foi lindo')).dy;
      final photo = tester
          .getTopLeft(find.byKey(const Key('post-photo-p1')))
          .dy;
      final tagged = tester
          .getTopLeft(find.byKey(const Key('post-tagged-p1')))
          .dy;
      expect(title, lessThan(text));
      expect(text, lessThan(photo));
      expect(photo, lessThan(tagged));
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

  testWidgets(
    'seletor de pessoas mostra a foto de perfil de cada pessoa na lista',
    (tester) async {
      final g = await gateway();
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
      await tester.enterText(find.byKey(const Key('tag-search')), 'an');
      await tester.pumpAndSettle();
      // Uma foto de perfil (avatar) por pessoa, no lugar do ícone genérico.
      expect(find.byType(ProfileAvatar), findsNWidgets(2));
    },
  );

  testWidgets(
    'na minha publicação o ícone de marcar é um atalho: abre o seletor e grava as marcações',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Map<String, dynamic>? patch;
      final g = IdentityGateway(
        cognito: Uri.parse('https://cognito.example'),
        api: Uri.parse('https://api.example'),
        clientId: 'synthetic',
        sleeper: (_) async {},
        transport: (uri, method, headers, body) async {
          if (uri.host == 'cognito.example') {
            return const JsonReply(200, {
              'AuthenticationResult': {'AccessToken': 'synthetic'},
            });
          }
          if (uri.path == '/participations/p9' && method == 'PATCH') {
            patch = Map<String, dynamic>.from(body! as Map);
            return const JsonReply(200, {'id': 'p9'});
          }
          if (uri.path == '/profiles') {
            return const JsonReply(200, {
              'items': [
                {
                  'id': 'u2',
                  'displayName': '[FICTICIA] Beto',
                  'username': 'beto',
                },
              ],
            });
          }
          return const JsonReply(404, {'code': 'NOT_FOUND'});
        },
      );
      await g.signIn('synthetic@example.test', 'synthetic');
      var changed = 0;
      final mine = entryFromPost(
        {
          'id': 'p9',
          'author': {'id': 'me', 'displayName': 'Eu', 'username': 'eu'},
          'participation': {
            'id': 'p9',
            'editionId': 'E1',
            'state': 'completed',
            'version': 4,
          },
          'publishedAt': '2026-11-01T10:00:00Z',
          'comment': 'Minha',
        },
        null,
        'me',
      );
      expect(mine.mine, isTrue);
      expect(mine.tagged, isEmpty);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                PostCard(gateway: g, entry: mine, onChanged: () => changed++),
              ],
            ),
          ),
        ),
      );
      // Sem ninguém marcado, o ícone aparece mesmo assim, como atalho.
      final icon = find.byKey(const Key('post-tagged-p9'));
      expect(icon, findsOneWidget);
      await tester.ensureVisible(icon);
      await tester.tap(icon);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tag-search')),
        findsOneWidget,
      ); // abriu o seletor direto
      await tester.enterText(find.byKey(const Key('tag-search')), 'be');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag-option-u2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag-done')));
      await tester.pumpAndSettle();
      expect(patch, {
        'expectedVersion': 4,
        'taggedUserIds': ['u2'],
      });
      expect(changed, 1);
    },
  );

  testWidgets(
    'na publicação de outra pessoa, sem marcados, o ícone não aparece',
    (tester) async {
      final g = await gateway();
      final other = entryFromPost(
        {
          'id': 'p8',
          'author': {'id': 'x', 'displayName': 'Autora', 'username': 'autora'},
          'participation': {
            'id': 'p8',
            'editionId': 'E1',
            'state': 'completed',
          },
          'publishedAt': '2026-11-01T10:00:00Z',
        },
        null,
        'me',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [PostCard(gateway: g, entry: other)],
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('post-tagged-p8')), findsNothing);
    },
  );
}
