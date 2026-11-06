import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/friends.dart';
import 'package:runpass/identity_gateway.dart';

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

Map<String, dynamic> person(
  String id, {
  String state = 'none',
  bool priv = false,
}) => {
  'id': id,
  'displayName': 'Pessoa $id',
  'username': 'user_$id',
  'version': 1,
  'isPrivate': priv,
  'followState': state,
};

void main() {
  testWidgets(
    'searching friends lists people and opens a profile that can be followed',
    (tester) async {
      final calls = <String>[];
      var state = 'none';
      final gateway = await gatewayWith((uri, method, headers, body) async {
        calls.add('$method ${uri.path} ${uri.queryParameters}');
        if (uri.path == '/profiles') {
          return JsonReply(200, {
            'items': [person('ana', state: state)],
          });
        }
        if (uri.path == '/profiles/ana/follow') {
          state = method == 'PUT' ? 'active' : 'none';
          return JsonReply(200, {
            'profileId': 'ana',
            'active': state == 'active',
          });
        }
        if (uri.path == '/profiles/ana') {
          return JsonReply(200, {
            ...person('ana', state: state),
            'canView': true,
            'followersCount': state == 'active' ? 1 : 0,
            'followingCount': 0,
            'participationCount': 0,
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: FriendSearchScreen(gateway: gateway)),
      );
      await tester.enterText(find.byKey(const Key('friend-search-field')), 'a');
      await tester.tap(find.byKey(const Key('friend-search-button')));
      await tester.pumpAndSettle();
      expect(
        find.text('Digite pelo menos 2 letras do nome ou do usuário.'),
        findsOneWidget,
      );
      expect(calls, isEmpty);

      await tester.enterText(
        find.byKey(const Key('friend-search-field')),
        'ana',
      );
      await tester.tap(find.byKey(const Key('friend-search-button')));
      await tester.pumpAndSettle();
      expect(calls.first, contains('q: ana'));
      expect(find.text('Pessoa ana'), findsOneWidget);

      await tester.tap(find.byKey(const Key('friend-ana')));
      await tester.pumpAndSettle();
      expect(find.text('Seguir'), findsOneWidget);
      await tester.tap(find.byKey(const Key('follow-button')));
      await tester.pumpAndSettle();
      expect(
        calls.any((c) => c.startsWith('PUT /profiles/ana/follow')),
        isTrue,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('follow-button')),
          matching: find.text('Seguindo'),
        ),
        findsOneWidget,
      );
      expect(find.text('1'), findsWidgets);
    },
  );

  testWidgets('a private profile hides content until the follow is accepted', (
    tester,
  ) async {
    final gateway = await gatewayWith((uri, method, headers, body) async {
      if (uri.path == '/profiles/bia') {
        return JsonReply(200, {
          ...person('bia', state: 'pending', priv: true),
          'canView': false,
        });
      }
      return const JsonReply(404, {'code': 'PROFILE_NOT_FOUND'});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PublicProfileScreen(gateway: gateway, profileId: 'bia'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('private-profile')), findsOneWidget);
    expect(find.textContaining('Solicitado'), findsOneWidget);
    expect(find.text('Seguidores'), findsNothing);
  });

  testWidgets('follow requests can be accepted', (tester) async {
    final calls = <String>[];
    var pending = true;
    final gateway = await gatewayWith((uri, method, headers, body) async {
      calls.add('$method ${uri.path}');
      if (method == 'GET') {
        return JsonReply(200, {
          'items': pending
              ? [
                  {
                    'profile': person('caio'),
                    'requestedAt': '2026-11-06T10:00:00Z',
                  },
                ]
              : [],
        });
      }
      pending = false;
      return const JsonReply(200, {'profileId': 'caio', 'active': true});
    });
    await tester.pumpWidget(
      MaterialApp(home: FollowRequestsScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('approve-caio')));
    await tester.pumpAndSettle();
    expect(calls, contains('PUT /me/follow-requests/caio'));
    expect(find.byKey(const Key('no-requests')), findsOneWidget);
  });

  testWidgets('comments are listed, sent and can be removed by their author', (
    tester,
  ) async {
    final comments = <Map<String, dynamic>>[
      {
        'id': 'c1',
        'postId': 'p1',
        'author': person('ana'),
        'text': 'Parabéns!',
        'createdAt': '2026-11-06T10:00:00Z',
        'version': 1,
        'edited': false,
      },
    ];
    final calls = <String>[];
    final gateway = await gatewayWith((uri, method, headers, body) async {
      calls.add('$method ${uri.path}');
      if (method == 'POST') {
        comments.add({
          'id': 'c2',
          'postId': 'p1',
          'author': person('eu'),
          'text': body?['text'],
          'createdAt': '2026-11-06T11:00:00Z',
          'version': 1,
          'edited': false,
        });
        return const JsonReply(201, {'id': 'c2'});
      }
      if (method == 'DELETE') {
        comments.removeWhere((c) => c['id'] == 'c2');
        return const JsonReply(200, {'id': 'c2', 'deleted': true});
      }
      return JsonReply(200, {'items': List.of(comments)});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: CommentsScreen(
          gateway: gateway,
          postId: 'p1',
          title: 'Corrida X',
          myId: 'eu',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Parabéns!'), findsOneWidget);
    expect(find.byKey(const Key('delete-comment-c1')), findsNothing);
    await tester.enterText(find.byKey(const Key('comment-field')), 'Muito bom');
    await tester.tap(find.byKey(const Key('comment-send')));
    await tester.pumpAndSettle();
    expect(find.text('Muito bom'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-comment-c2')));
    await tester.pumpAndSettle();
    expect(find.text('Muito bom'), findsNothing);
    expect(calls, contains('DELETE /comments/c2'));
  });

  testWidgets('the privacy switch sends isPrivate with the current version', (
    tester,
  ) async {
    Map<String, dynamic>? sent;
    final gateway = await gatewayWith((uri, method, headers, body) async {
      sent = body;
      return JsonReply(200, {...person('eu', priv: true), 'version': 2});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PrivacyTile(gateway: gateway, profile: person('eu')),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('private-switch')));
    await tester.pumpAndSettle();
    expect(sent, {'expectedVersion': 1, 'isPrivate': true});
    expect(find.textContaining('Só quem você aceitar'), findsOneWidget);
  });
}
