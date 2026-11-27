import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/post_card.dart' show postPhotoFrameRatio;
import 'package:runpass/my_races.dart' show MedalPhoto;
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/runpass_theme.dart';

void main() {
  test('quadro da foto: a proporção da foto, entre 4:5 e 1,91:1', () {
    expect(postPhotoFrameRatio(null), 4 / 5); // ainda sem saber: retrato
    expect(postPhotoFrameRatio(1), 1); // quadrada, inteira
    expect(
      postPhotoFrameRatio(4 / 3),
      closeTo(4 / 3, 1e-9),
    ); // horizontal, inteira
    expect(postPhotoFrameRatio(3), 1.91); // muito larga: limita
    expect(postPhotoFrameRatio(0.5), 4 / 5); // muito alta: limita
  });

  testWidgets(
    'publicacao de amigo mostra a foto da medalha e o ultimo comentario em destaque',
    (tester) async {
      final paths = <String>[];
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
              'id': 'me',
              'displayName': 'Eu',
              'username': 'eu',
              'version': 2,
            });
          }
          if (uri.path == '/feed') {
            return const JsonReply(200, {
              'items': [
                {
                  'id': 'p-amiga',
                  'author': {
                    'id': 'amiga',
                    'displayName': 'Amiga Corredora',
                    'username': 'amiga',
                    'version': 1,
                  },
                  'participation': {
                    'id': 'p-amiga',
                    'editionId': 'E1',
                    'distanceId': '10k',
                    'state': 'completed',
                  },
                  'publishedAt': '2026-11-05T10:00:00Z',
                  'commentCount': 3,
                  'likeCount': 2,
                  'likedByMe': false,
                  'lastComment': {
                    'id': 'c3',
                    'text': 'Último comentário: parabéns, até a próxima!',
                    'createdAt': '2026-11-06T09:00:00Z',
                    'author': {
                      'id': 'x',
                      'displayName': 'Comentarista',
                      'username': 'x',
                      'version': 1,
                    },
                  },
                },
              ],
            });
          }
          return const JsonReply(200, {'items': []});
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      // A foto da medalha de quem nao sou eu tambem e pedida ao servidor.
      expect(paths, contains('/participations/p-amiga/image'));
      expect(find.byKey(const Key('last-comment-p-amiga')), findsOneWidget);
      expect(
        find.text('Último comentário: parabéns, até a próxima!'),
        findsOneWidget,
      );
      expect(find.text('Comentarista'), findsOneWidget);
      expect(find.text('Ver todos os 3 comentários'), findsOneWidget);
      expect(find.byKey(const Key('notifications-bell')), findsOneWidget);
      // Compartilhar abre a folha do sistema (WhatsApp, e-mail, Instagram, Facebook...).
      expect(find.byKey(const Key('share-p-amiga')), findsOneWidget);
      expect(find.text('Compartilhar'), findsNothing); // só o ícone
    },
  );

  testWidgets(
    'tocar no nome da corrida na publicação abre as informações dela',
    (tester) async {
      final paths = <String>[];
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
              'id': 'me',
              'displayName': 'Eu',
              'username': 'eu',
              'version': 2,
            });
          }
          if (uri.path == '/feed') {
            return const JsonReply(200, {
              'items': [
                {
                  'id': 'p1',
                  'author': {
                    'id': 'amiga',
                    'displayName': 'Amiga',
                    'username': 'amiga',
                    'version': 1,
                  },
                  'participation': {
                    'id': 'p1',
                    'editionId': 'E1',
                    'distanceId': '10k',
                    'state': 'completed',
                  },
                  'publishedAt': '2026-11-05T10:00:00Z',
                  'commentCount': 0,
                  'likeCount': 0,
                  'likedByMe': false,
                },
              ],
            });
          }
          if (uri.path == '/editions/E1') {
            return const JsonReply(200, {
              'id': 'E1',
              'name': '[FICTICIA] Corrida E1',
              'date': '2026-09-01',
              'city': 'São Paulo',
              'state': 'SP',
              'status': 'past',
              'version': 1,
              'distances': [
                {'id': '10k', 'kilometers': 10},
              ],
            });
          }
          return const JsonReply(200, {'items': []});
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      // Foto como no Instagram: quadro 4:5 de ponta a ponta do cartão.
      final frame = tester.widget<AspectRatio>(
        find
            .ancestor(
              of: find.byKey(const Key('post-photo-p1')),
              matching: find.byType(AspectRatio),
            )
            .first,
      );
      expect(frame.aspectRatio, 4 / 5);
      final card = tester.getRect(
        find
            .ancestor(
              of: find.byKey(const Key('post-photo-p1')),
              matching: find.byType(Card),
            )
            .first,
      );
      final photo = tester.getRect(find.byKey(const Key('post-photo-p1')));
      expect(
        photo.width,
        closeTo(card.width - 8, 1),
      ); // o Card tem 4 de margem de cada lado
      // Título, texto e números (km, tempo, pace) ficam juntos, antes da foto.
      final summary = tester.getRect(find.byKey(const Key('post-summary-p1')));
      expect(
        tester.getRect(find.byKey(const Key('post-race-p1'))).bottom,
        lessThanOrEqualTo(summary.top),
      );
      expect(summary.bottom, lessThanOrEqualTo(photo.top));
      expect(
        find.descendant(
          of: find.byKey(const Key('post-summary-p1')),
          matching: find.text('Distância'),
        ),
        findsOneWidget,
      );
      // Em negrito e sem sublinhado: o link é só o nome da corrida.
      final title = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('post-race-p1')),
          matching: find.byType(Text),
        ),
      );
      expect(title.style?.fontWeight, FontWeight.w800);
      expect(title.style?.decoration, isNull);
      // A foto preenche o quadro de ponta a ponta, sem faixas pretas (cobre e corta o excesso).
      expect(
        tester.widget<MedalPhoto>(find.byKey(const Key('post-photo-p1'))).fit,
        BoxFit.cover,
      );
      expect(
        find.descendant(
          of: find
              .ancestor(
                of: find.byKey(const Key('post-photo-p1')),
                matching: find.byType(AspectRatio),
              )
              .first,
          matching: find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == Colors.black,
          ),
        ),
        findsNothing,
      );
      // O nome da corrida fica ACIMA da foto, fora dela (não por cima da imagem).
      final name = tester.getRect(find.byKey(const Key('post-race-p1')));
      expect(name.bottom, lessThanOrEqualTo(photo.top));
      // Sem a foto carregada, o quadro fica em 4:5 (retrato); com foto, acompanha a proporção dela.
      await tester.ensureVisible(find.byKey(const Key('post-race-p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-race-p1')));
      await tester.pumpAndSettle();
      expect(paths, contains('/editions/E1'));
      expect(
        find.text('Avaliações'),
        findsOneWidget,
      ); // abas da tela da corrida
      expect(find.text('Participantes'), findsOneWidget);
    },
  );

  testWidgets(
    '"Pra você" sem estado/cidade cadastrados pede uma vez e depois mostra as corridas indicadas',
    (tester) async {
      final patches = <Map<String, dynamic>?>[];
      Map<String, dynamic> me = {
        'id': 'eu',
        'displayName': 'Eu',
        'username': 'eu',
        'version': 2,
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
          if (method == 'PATCH' && uri.path == '/me') {
            patches.add(body);
            me = {...me, ...?body, 'version': 3};
            me.remove('expectedVersion');
            return JsonReply(200, me);
          }
          if (uri.path == '/me') return JsonReply(200, me);
          if (uri.path == '/feed') {
            return const JsonReply(200, {
              'items': [
                {
                  'id': 'p-ac',
                  'author': {
                    'id': 'outra',
                    'displayName': 'Corredora do Acre',
                    'username': 'outra',
                    'version': 1,
                  },
                  'participation': {
                    'id': 'p-ac',
                    'editionId': 'E1',
                    'distanceId': '10k',
                    'state': 'completed',
                  },
                  'publishedAt': '2026-11-05T10:00:00Z',
                },
              ],
            });
          }
          if (uri.path == '/editions/E1') {
            return const JsonReply(200, {
              'id': 'E1',
              'name': 'Corrida do Acre',
              'city': 'Acrelândia',
              'state': 'AC',
              'date': '2026-11-01',
            });
          }
          return const JsonReply(200, {'items': []});
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pra você'));
      await tester.pumpAndSettle();
      // Pede estado/cidade antes de indicar.
      expect(find.text('Estado e cidade'), findsOneWidget);
      await tester.tap(find.byKey(const Key('location-done')));
      await tester.pumpAndSettle();
      expect(patches, [
        {
          'expectedVersion': 2,
          'state': 'AC',
          'city': 'Acrelândia',
          'latitude': -9.82581,
          'longitude': -66.8972,
        },
      ]);
      // Com a cidade salva, aparecem as corridas indicadas (no lugar das publicações).
      expect(find.text('Corredora do Acre'), findsNothing);
      expect(
        find.byKey(const Key('recommended-empty')).evaluate().isNotEmpty ||
            find.byKey(const Key('recommended-races')).evaluate().isNotEmpty,
        isTrue,
      );
      // Tocar de novo nao pergunta outra vez.
      await tester.tap(find.text('Todos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pra você'));
      await tester.pumpAndSettle();
      expect(find.text('Estado e cidade'), findsNothing);
      expect(patches, hasLength(1));
    },
  );

  testWidgets(
    '"Amigos" e "Seguindo" sem nenhum vinculo convidam a encontrar pessoas',
    (tester) async {
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
              'id': 'eu',
              'displayName': 'Eu',
              'username': 'eu',
              'version': 2,
            });
          }
          if (uri.path == '/profiles/eu') {
            return const JsonReply(200, {
              'id': 'eu',
              'displayName': 'Eu',
              'username': 'eu',
              'version': 2,
              'canView': true,
              'followersCount': 0,
              'followingCount': 0,
              'friendsCount': 0,
              'participationCount': 0,
            });
          }
          return const JsonReply(200, {'items': []});
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Amigos'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Você ainda não tem amigos confirmados'),
        findsOneWidget,
      );
      expect(find.text('Encontrar amigos'), findsOneWidget);
      await tester.tap(find.text('Seguindo'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Você ainda não está seguindo ninguém'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('find-friends-empty-state')), findsOneWidget);
      expect(find.text('Encontrar pessoas'), findsOneWidget);
      await tester.tap(find.byKey(const Key('find-friends-empty-state')));
      await tester.pumpAndSettle();
      expect(find.text('Buscar amigos'), findsOneWidget);
    },
  );

  testWidgets(
    'o destaque laranja do filtro segue a seleção, não fica fixo em "Todos"',
    (tester) async {
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
              'id': 'eu',
              'displayName': 'Eu',
              'username': 'eu',
              'version': 2,
            });
          }
          return const JsonReply(200, {'items': []});
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      Color circleColorOf(FeedFilter filter) {
        final container = tester.widget<Container>(
          find
              .ancestor(
                of: find.byIcon(filter.icon),
                matching: find.byWidgetPredicate(
                  (w) => w is Container && w.decoration is BoxDecoration,
                ),
              )
              .first,
        );
        return (container.decoration as BoxDecoration).color!;
      }

      expect(circleColorOf(FeedFilter.all), runPassOrange);
      expect(circleColorOf(FeedFilter.friends), isNot(runPassOrange));

      await tester.tap(find.text('Amigos'));
      await tester.pumpAndSettle();

      expect(circleColorOf(FeedFilter.friends), runPassOrange);
      expect(circleColorOf(FeedFilter.all), isNot(runPassOrange));
    },
  );

  // Dados fictícios [FICTICIA].
  Map<String, dynamic> friendPost(String id, String at) => {
    'id': id,
    'author': {
      'id': 'amiga',
      'displayName': 'Amiga Corredora',
      'username': 'amiga',
      'version': 1,
    },
    'participation': {
      'id': id,
      'editionId': 'E1',
      'distanceId': '10k',
      'state': 'completed',
      'completedAt': at,
    },
    'publishedAt': at,
    'commentCount': 0,
    'likeCount': 0,
    'likedByMe': false,
  };

  Future<IdentityGateway> feedGateway(
    Future<JsonReply> Function(Uri uri) feed,
  ) async {
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
            'id': 'me',
            'displayName': 'Eu',
            'username': 'eu',
            'version': 2,
          });
        }
        if (uri.path == '/feed') return feed(uri);
        return const JsonReply(200, {'items': []});
      },
    );
    await gateway.signIn('synthetic@example.test', 'synthetic');
    return gateway;
  }

  testWidgets(
    '"Carregar mais" pede a página seguinte do feed e junta à lista',
    (tester) async {
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cursors = <String?>[];
      final gateway = await feedGateway((uri) async {
        final cursor = uri.queryParameters['cursor'];
        cursors.add(cursor);
        return cursor == null
            ? JsonReply(200, {
                'items': [friendPost('p1', '2026-11-05T10:00:00Z')],
                'nextCursor': 'c2',
              })
            : JsonReply(200, {
                'items': [friendPost('p2', '2026-11-01T10:00:00Z')],
              });
      });
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('share-p1')), findsOneWidget);
      expect(find.byKey(const Key('share-p2')), findsNothing);
      await tester.tap(find.byKey(const Key('feed-load-more')));
      await tester.pumpAndSettle();
      expect(cursors, [null, 'c2']);
      expect(find.byKey(const Key('share-p1')), findsOneWidget);
      expect(find.byKey(const Key('share-p2')), findsOneWidget);
      expect(find.byKey(const Key('feed-load-more')), findsNothing); // acabou
    },
  );

  testWidgets(
    'feed sem resposta avisa e deixa tentar de novo, em vez de parecer conta vazia',
    (tester) async {
      var fail = true;
      final gateway = await feedGateway(
        (uri) async => fail
            ? const JsonReply(400, {'code': 'INVALID_REQUEST'})
            : JsonReply(200, {
                'items': [friendPost('p1', '2026-11-05T10:00:00Z')],
              }),
      );
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feed-failed')), findsOneWidget);
      expect(find.text('Encontrar corridas'), findsNothing);
      fail = false;
      await tester.tap(find.byKey(const Key('feed-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feed-failed')), findsNothing);
      expect(find.byKey(const Key('share-p1')), findsOneWidget);
    },
  );
}
