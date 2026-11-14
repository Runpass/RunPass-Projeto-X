import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/notifications.dart';
import 'package:runpass/settings.dart';

Future<IdentityGateway> gatewayWith(JsonTransport handler) async {
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
      return handler(uri, method, headers, body);
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return gateway;
}

Map<String, dynamic> who(String id) => {
  'id': id,
  'displayName': 'Pessoa $id',
  'username': 'user_$id',
  'version': 1,
};

void main() {
  test('o texto de cada tipo de aviso', () {
    String text(String kind, [String? extra]) =>
        notificationText({'kind': kind, 'actor': who('a'), 'text': extra});
    expect(text('friend_request'), 'Pessoa a quer ser seu amigo.');
    expect(text('friend'), 'Você e Pessoa a agora são amigos.');
    expect(text('follow'), 'Pessoa a começou a seguir você.');
    expect(text('like'), 'Pessoa a curtiu sua publicação.');
    expect(text('comment', 'Show'), 'Pessoa a comentou: “Show”');
    expect(text('post'), 'Pessoa a publicou uma conquista.');
  });

  testWidgets(
    'tela de avisos: secao de pedidos de amizade com contagem, marca como lido',
    (tester) async {
      final calls = <String>[];
      var accepted = false;
      final gateway = await gatewayWith((uri, method, headers, body) async {
        calls.add('$method ${uri.path}');
        if (uri.path == '/me/notifications') {
          return JsonReply(200, {
            'unreadCount': 2,
            'items': [
              {
                'id': accepted ? 'friend:b' : 'friend_request:b',
                'kind': accepted ? 'friend' : 'friend_request',
                'createdAt': '2026-11-06T10:00:00Z',
                'unread': true,
                'actor': who('b'),
              },
              {
                'id': 'like:c',
                'kind': 'like',
                'createdAt': '2026-11-06T09:00:00Z',
                'unread': true,
                'actor': who('c'),
                'postId': 'p1',
              },
            ],
          });
        }
        if (uri.path == '/me/friend-requests') {
          return JsonReply(200, {
            'items': accepted
                ? []
                : [
                    {
                      'profile': who('b'),
                      'requestedAt': '2026-11-06T10:00:00Z',
                    },
                  ],
          });
        }
        if (uri.path == '/me/friend-requests/b') {
          accepted = true;
          return const JsonReply(200, {'profileId': 'b', 'state': 'friends'});
        }
        return const JsonReply(200, {'readAt': '2026-11-06T11:00:00Z'});
      });
      await tester.pumpWidget(
        MaterialApp(home: NotificationsScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      // Pedido de amizade nao aparece solto na lista, so no resumo com contagem.
      expect(find.text('Pessoa b quer ser seu amigo.'), findsNothing);
      expect(find.text('Pedidos de amizade (1)'), findsOneWidget);
      expect(find.text('Pessoa c curtiu sua publicação.'), findsOneWidget);
      // O aviso no celular fica so nas configuracoes.
      expect(find.byKey(const Key('os-alerts-switch')), findsNothing);
      expect(calls, contains('POST /me/notifications/read'));

      await tester.tap(find.byKey(const Key('friend-requests-section')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('approve-b')));
      await tester.pumpAndSettle();
      expect(calls, contains('PUT /me/friend-requests/b'));
      expect(find.byKey(const Key('no-requests')), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Pedidos de amizade (1)'), findsNothing);
    },
  );

  testWidgets(
    'aviso da equipe (sem autor) mostra o motivo e leva a Minhas solicitações',
    (tester) async {
      const texto =
          'Sua sugestão da corrida "Corrida X" não foi aprovada pela equipe: duplicada. '
          'As informações enviadas deixam de aparecer para você.';
      final gateway = await gatewayWith((uri, method, headers, body) async {
        if (uri.path == '/me/notifications') {
          return const JsonReply(200, {
            'unreadCount': 1,
            'items': [
              {
                'id': 'request_rejected:r1:2026-11-14T10:00:00Z',
                'kind': 'request_rejected',
                'createdAt': '2026-11-14T10:00:00Z',
                'unread': true,
                'text': texto,
                'requestId': 'r1',
              },
            ],
          });
        }
        if (uri.path == '/me/edition-requests') {
          return const JsonReply(200, {'items': []});
        }
        return const JsonReply(200, {});
      });
      await tester.pumpWidget(
        MaterialApp(home: NotificationsScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('team-notice-r1')), findsOneWidget);
      expect(find.text(texto), findsOneWidget);
      expect(
        notificationText({
          'kind': 'banner_dismissed',
          'text': 'Banner não aprovado.',
        }),
        'Banner não aprovado.',
      );
      await tester.tap(find.byKey(const Key('team-notice-r1')));
      await tester.pumpAndSettle();
      expect(find.text('Minhas solicitações'), findsOneWidget);
    },
  );

  testWidgets('sem avisos a tela explica o que aparece ali', (tester) async {
    final gateway = await gatewayWith(
      (uri, method, headers, body) async =>
          const JsonReply(200, {'items': [], 'unreadCount': 0}),
    );
    await tester.pumpWidget(
      MaterialApp(home: NotificationsScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('no-notifications')), findsOneWidget);
    // Fica sempre visível, mesmo sem nenhum pedido pendente.
    expect(find.byKey(const Key('friend-requests-section')), findsOneWidget);
    expect(find.text('Pedidos de amizade (0)'), findsOneWidget);
  });

  testWidgets('perfil privado fica nas configuracoes', (tester) async {
    final bodies = <Map<String, dynamic>?>[];
    final gateway = await gatewayWith((uri, method, headers, body) async {
      if (method == 'PATCH') {
        bodies.add(body);
        return const JsonReply(200, {
          'id': 'u1',
          'version': 2,
          'isPrivate': true,
        });
      }
      return const JsonReply(200, {
        'id': 'u1',
        'displayName': 'Eu',
        'username': 'eu',
        'version': 1,
        'isPrivate': false,
      });
    });
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('private-switch')));
    await tester.pumpAndSettle();
    expect(bodies, [
      {'expectedVersion': 1, 'isPrivate': true},
    ]);
    expect(find.byKey(const Key('os-alerts-switch')), findsOneWidget);
    expect(find.byKey(const Key('sign-out')), findsOneWidget);
    expect(find.byKey(const Key('delete-account')), findsOneWidget);
  });

  testWidgets('deslizar para a esquerda apaga o aviso; pedido nao desliza', (
    tester,
  ) async {
    final calls = <String>[];
    final gateway = await gatewayWith((uri, method, headers, body) async {
      calls.add('$method ${uri.path}');
      if (uri.path == '/me/notifications') {
        return JsonReply(200, {
          'unreadCount': 0,
          'items': [
            {
              'id': 'friend_request:b::2026',
              'kind': 'friend_request',
              'createdAt': '2026-11-06T10:00:00Z',
              'unread': false,
              'actor': who('b'),
            },
            {
              'id': 'like:c:p1:2026',
              'kind': 'like',
              'createdAt': '2026-11-06T09:00:00Z',
              'unread': false,
              'actor': who('c'),
              'postId': 'p1',
            },
          ],
        });
      }
      return const JsonReply(200, {'id': 'x', 'dismissed': true});
    });
    await tester.pumpWidget(
      MaterialApp(home: NotificationsScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    // Pedido de amizade fica so no resumo com contagem, nunca como Dismissible solto.
    expect(find.byType(Dismissible), findsOneWidget);
    await tester.drag(find.byType(Dismissible), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Pessoa c curtiu sua publicação.'), findsNothing);
    expect(find.text('Pedidos de amizade (1)'), findsOneWidget);
    expect(calls, contains('DELETE /me/notifications/like%3Ac%3Ap1%3A2026'));
  });

  testWidgets('tocar num aviso de curtida abre a publicacao', (tester) async {
    final calls = <String>[];
    final gateway = await gatewayWith((uri, method, headers, body) async {
      calls.add('$method ${uri.path}');
      if (uri.path == '/me/notifications') {
        return JsonReply(200, {
          'unreadCount': 0,
          'items': [
            {
              'id': 'like:c:p1:2026',
              'kind': 'like',
              'createdAt': '2026-11-06T09:00:00Z',
              'unread': false,
              'actor': who('c'),
              'postId': 'p1',
            },
          ],
        });
      }
      if (uri.path == '/posts/p1') {
        return JsonReply(200, {
          'id': 'p1',
          'author': who('me'),
          'participation': {
            'id': 'p1',
            'editionId': 'E1',
            'distanceId': '10k',
            'state': 'completed',
          },
          'publishedAt': '2026-11-05T10:00:00Z',
          'commentCount': 0,
          'likeCount': 1,
          'likedByMe': false,
        });
      }
      return const JsonReply(200, {'id': 'me', 'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(home: NotificationsScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pessoa c curtiu sua publicação.'));
    await tester.pumpAndSettle();
    expect(calls, contains('GET /posts/p1'));
    expect(find.text('Publicação'), findsOneWidget);
    expect(find.byKey(const Key('share-p1')), findsOneWidget);
  });

  testWidgets('aviso de novo seguidor oferece Seguir de volta', (tester) async {
    final calls = <String>[];
    final gateway = await gatewayWith((uri, method, headers, body) async {
      calls.add('$method ${uri.path}');
      if (uri.path == '/me/notifications') {
        return JsonReply(200, {
          'unreadCount': 0,
          'items': [
            {
              'id': 'follow:b::2026',
              'kind': 'follow',
              'createdAt': '2026-11-06T10:00:00Z',
              'unread': false,
              'actor': {...who('b'), 'followState': 'none'},
            },
          ],
        });
      }
      return const JsonReply(200, {'profileId': 'b', 'state': 'active'});
    });
    await tester.pumpWidget(
      MaterialApp(home: NotificationsScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notification-follow-back-b')));
    await tester.pumpAndSettle();
    expect(calls, contains('PUT /profiles/b/follow'));
    expect(find.byKey(const Key('notification-follow-back-b')), findsNothing);
  });
}
