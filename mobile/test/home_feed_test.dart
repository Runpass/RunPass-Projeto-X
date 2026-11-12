import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/runpass_theme.dart';

void main() {
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
      expect(find.text('Compartilhar'), findsOneWidget);
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
      // Em negrito e sem sublinhado: o link é só o nome da corrida.
      final title = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('post-race-p1')),
          matching: find.byType(Text),
        ),
      );
      expect(title.style?.fontWeight, FontWeight.w800);
      expect(title.style?.decoration, isNull);
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
    '"Minha Cidade" sem estado/cidade cadastrados pede uma vez e depois filtra',
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
      await tester.tap(find.text('Minha Cidade'));
      await tester.pumpAndSettle();
      // Pede estado/cidade antes de aplicar o filtro.
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
      // Com a cidade salva, a publicacao da mesma cidade aparece.
      expect(find.text('Corredora do Acre'), findsOneWidget);
      // Tocar de novo nao pergunta outra vez.
      await tester.tap(find.text('Todos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Minha Cidade'));
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
}
