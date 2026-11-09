import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';

Map<String, dynamic> edition(
  String id,
  String name,
  String date,
  String city,
  String state,
  num km,
) => {
  'id': id,
  'name': name,
  'date': date,
  'city': city,
  'state': state,
  'status': 'past',
  'version': 1,
  'distances': [
    {'id': 'd', 'kilometers': km},
  ],
};

Map<String, dynamic> done(
  String id,
  String editionId, {
  int? seconds,
  bool published = false,
  String? completedAt,
}) => {
  'id': id,
  'editionId': editionId,
  'distanceId': 'd',
  'state': 'completed',
  'version': 2,
  'timeSeconds': ?seconds,
  if (seconds != null) 'paceSecondsPerKm': seconds ~/ 5,
  'publishToFeed': published,
  'completedAt': ?completedAt,
};

Future<IdentityGateway> runner({bool noRaces = false}) async {
  final editions = {
    'a': edition('a', 'Corrida A', '2026-09-01', 'São Paulo', 'SP', 5),
    'b': edition('b', 'Corrida B', '2025-05-01', 'Rio de Janeiro', 'RJ', 10),
  };
  final gateway = IdentityGateway(
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
          'displayName': 'Corredor Teste',
          'username': 'teste',
          'city': 'Santos',
          'version': 1,
        });
      }
      if (uri.path == '/me/participations') {
        return JsonReply(200, {
          'items': noRaces
              ? []
              : [
                  done('p1', 'a', seconds: 1500),
                  done('p2', 'b'),
                  {...done('p3', 'a'), 'state': 'draft'},
                ],
        });
      }
      final match = editions[uri.pathSegments.last];
      return match == null
          ? const JsonReply(404, {'code': 'EDITION_NOT_FOUND'})
          : JsonReply(200, match);
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return gateway;
}

void main() {
  testWidgets(
    'medal collection shows counts and regroups by year and distance',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: MedalCollectionScreen(gateway: await runner())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Meu Medalheiro'), findsOneWidget);
      expect(find.text('Corrida A'), findsOneWidget);
      expect(find.text('Corrida B'), findsOneWidget);
      // Two completed races in two cities; the draft is not a medal.
      expect(find.text('medalhas'), findsOneWidget);
      expect(find.text("km's\ncorridos"), findsOneWidget);
      expect(find.text('cidades\nvisitadas'), findsOneWidget);
      expect(find.text('países\nvisitados'), findsOneWidget);
      // Medalhas e cidades valem 2; edicoes sem pais contam como Brasil (1 pais).
      expect(find.text('2'), findsNWidgets(2));
      expect(find.text('1'), findsOneWidget);
      await tester.tap(find.text('Por ano'));
      await tester.pumpAndSettle();
      expect(find.text('2026'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('2025'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('2025'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Por distância'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Por distância'));
      await tester.pumpAndSettle();
      expect(find.text('5K'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('10K'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('10K'), findsOneWidget);
    },
  );

  testWidgets(
    'medal collection without completed races keeps the empty state',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(gateway: await runner(noRaces: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Você ainda não concluiu uma corrida. Sua primeira medalha aparecerá aqui.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('home highlights the latest conquest with time and pace', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: RunPassHomeScreen(gateway: await runner())),
    );
    await tester.pumpAndSettle();
    expect(find.text('concluiu Corrida A'), findsOneWidget);
    expect(find.text('5 km'), findsOneWidget);
    expect(find.text('25:00'), findsOneWidget);
    expect(find.text('5:00/km'), findsOneWidget);
  });

  testWidgets('profile summarizes completed races by distance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: RunnerProfileScreen(gateway: await runner())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Corredor Teste'), findsOneWidget);
    expect(find.text('@teste  •  Santos'), findsOneWidget);
    expect(find.byKey(const Key('profile-counts')), findsOneWidget);
    expect(find.text('seguidores'), findsOneWidget);
    expect(find.text('seguindo'), findsOneWidget);
    expect(find.text('provas\nconcluídas'), findsOneWidget);
    expect(find.text('corridas\n5K'), findsOneWidget);
    expect(find.text('corridas\n10K'), findsOneWidget);
    // Nenhuma das corridas de teste foi publicada no feed: secao vazia.
    expect(find.byKey(const Key('no-my-posts')), findsOneWidget);
  });

  testWidgets(
    'minhas publicações: só corridas publicadas, como cartões do Feed, mais recente primeiro',
    (tester) async {
      tester.view.physicalSize = const Size(1179, 4000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final paths = <String>[];
      final editions = {
        'a': edition('a', 'Corrida A', '2026-09-01', 'São Paulo', 'SP', 5),
        'b': edition(
          'b',
          'Corrida B',
          '2025-05-01',
          'Rio de Janeiro',
          'RJ',
          10,
        ),
      };
      final gateway = IdentityGateway(
        cognito: Uri.parse('https://cognito.example'),
        api: Uri.parse('https://api.example'),
        clientId: 'synthetic',
        transport: (uri, method, headers, body) async {
          if (uri.host == 'cognito.example') {
            return const JsonReply(200, {
              'AuthenticationResult': {'AccessToken': 'synthetic'},
            });
          }
          paths.add(uri.path);
          if (uri.path == '/me') {
            return const JsonReply(200, {
              'id': 'eu',
              'displayName': 'Corredor Teste',
              'username': 'teste',
              'version': 1,
            });
          }
          if (uri.path == '/me/participations') {
            return JsonReply(200, {
              'items': [
                done(
                  'p1',
                  'a',
                  published: true,
                  completedAt: '2026-09-02T10:00:00Z',
                ),
                done(
                  'p2',
                  'b',
                  published: true,
                  completedAt: '2025-05-02T10:00:00Z',
                ),
                done('p3', 'a'), // nao publicada: fica de fora da secao
              ],
            });
          }
          final post = {
            'p1': ('a', '2026-09-02T10:00:00Z'),
            'p2': ('b', '2025-05-02T10:00:00Z'),
          }[uri.pathSegments.last];
          if (uri.path.startsWith('/posts/') && post != null) {
            final (editionId, publishedAt) = post;
            return JsonReply(200, {
              'id': uri.pathSegments.last,
              'author': {
                'id': 'eu',
                'displayName': 'Corredor Teste',
                'username': 'teste',
                'version': 1,
              },
              'participation': {
                'id': uri.pathSegments.last,
                'editionId': editionId,
                'distanceId': 'd',
                'state': 'completed',
              },
              'publishedAt': publishedAt,
              'commentCount': 0,
              'likeCount': 0,
              'likedByMe': false,
            });
          }
          final match = editions[uri.pathSegments.last];
          return match == null
              ? const JsonReply(404, {'code': 'EDITION_NOT_FOUND'})
              : JsonReply(200, match);
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no-my-posts')), findsNothing);
      // Mesmo cartao do Feed (PostCard), um abaixo do outro — nao em grade.
      expect(find.byKey(const Key('my-post-p1')), findsOneWidget);
      expect(find.byKey(const Key('my-post-p2')), findsOneWidget);
      expect(find.byKey(const Key('my-post-p3')), findsNothing);
      expect(paths, containsAll(['/posts/p1', '/posts/p2']));
      // Mais recente primeiro: p1 (set/2026) acima de p2 (mai/2025).
      final p1Top = tester.getTopLeft(find.byKey(const Key('my-post-p1'))).dy;
      final p2Top = tester.getTopLeft(find.byKey(const Key('my-post-p2'))).dy;
      expect(p1Top, lessThan(p2Top));
      expect(find.text('concluiu Corrida A'), findsOneWidget);
      expect(find.text('concluiu Corrida B'), findsOneWidget);
    },
  );
}
