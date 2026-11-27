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
  String followState = 'none',
  String friendState = 'none',
}) => {
  'id': id,
  'displayName': 'Pessoa $id',
  'username': 'user_$id',
  'version': 1,
  'isPrivate': false,
  'followState': followState,
  'friendState': friendState,
};

void main() {
  testWidgets(
    'lista de seguidores mostra "Seguir de volta" quando e a minha propria lista',
    (tester) async {
      final calls = <String>[];
      final gateway = await gatewayWith((uri, method, headers, body) async {
        calls.add('$method ${uri.path}');
        if (uri.path == '/profiles/eu/followers') {
          return JsonReply(200, {
            'items': [person('ana', followState: 'none')],
          });
        }
        if (uri.path == '/profiles/ana/follow' && method == 'PUT') {
          return JsonReply(200, {'profileId': 'ana', 'state': 'active'});
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RelationListScreen(
            gateway: gateway,
            profileId: 'eu',
            kind: RelationListKind.followers,
            title: 'Seguidores',
            ownList: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pessoa ana'), findsOneWidget);
      expect(find.text('Seguir de volta'), findsOneWidget);

      await tester.tap(find.byKey(const Key('relation-follow-ana')));
      await tester.pumpAndSettle();
      expect(calls, contains('PUT /profiles/ana/follow'));
      expect(find.text('Seguindo'), findsOneWidget);
      expect(find.text('Seguir de volta'), findsNothing);
    },
  );

  testWidgets(
    'lista de seguidores de outra pessoa mostra "Seguir", nao "Seguir de volta"',
    (tester) async {
      final gateway = await gatewayWith((uri, method, headers, body) async {
        if (uri.path == '/profiles/ana/followers') {
          return JsonReply(200, {
            'items': [person('bia', followState: 'none')],
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RelationListScreen(
            gateway: gateway,
            profileId: 'ana',
            kind: RelationListKind.followers,
            title: 'Seguidores',
            ownList: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Seguir'), findsOneWidget);
      expect(find.text('Seguir de volta'), findsNothing);
    },
  );

  testWidgets(
    'lista de amigos mostra o botao de amizade, com toque atualizando o estado',
    (tester) async {
      final calls = <String>[];
      final gateway = await gatewayWith((uri, method, headers, body) async {
        calls.add('$method ${uri.path}');
        if (uri.path == '/profiles/eu/friends') {
          return JsonReply(200, {
            'items': [person('caio', friendState: 'none')],
          });
        }
        if (uri.path == '/profiles/caio/friend' && method == 'PUT') {
          return JsonReply(200, {'profileId': 'caio', 'state': 'pending_out'});
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RelationListScreen(
            gateway: gateway,
            profileId: 'eu',
            kind: RelationListKind.friends,
            title: 'Amigos',
            ownList: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Adicionar'), findsOneWidget);

      await tester.tap(find.byKey(const Key('relation-friend-caio')));
      await tester.pumpAndSettle();
      expect(calls, contains('PUT /profiles/caio/friend'));
      expect(find.text('Solicitado'), findsOneWidget);
    },
  );

  testWidgets('rolar a lista busca a proxima pagina pelo cursor', (
    tester,
  ) async {
    final calls = <String>[];
    final gateway = await gatewayWith((uri, method, headers, body) async {
      calls.add('${uri.path}?${uri.query}');
      if (uri.path == '/profiles/eu/following' &&
          !uri.queryParameters.containsKey('cursor')) {
        return JsonReply(200, {
          'items': [person('p1')],
          'nextCursor': 'p1',
        });
      }
      if (uri.path == '/profiles/eu/following' &&
          uri.queryParameters['cursor'] == 'p1') {
        return JsonReply(200, {
          'items': [person('p2')],
        });
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: RelationListScreen(
          gateway: gateway,
          profileId: 'eu',
          kind: RelationListKind.following,
          title: 'Seguindo',
          ownList: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pessoa p1'), findsOneWidget);
    // O builder dispara a proxima pagina ao desenhar o item placeholder do final da lista.
    await tester.pumpAndSettle();
    expect(find.text('Pessoa p2'), findsOneWidget);
    expect(calls.any((c) => c.contains('cursor=p1')), isTrue);
  });

  testWidgets('lista vazia mostra aviso', (tester) async {
    final gateway = await gatewayWith((uri, method, headers, body) async {
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: RelationListScreen(
          gateway: gateway,
          profileId: 'eu',
          kind: RelationListKind.friends,
          title: 'Amigos',
          ownList: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('relation-empty')), findsOneWidget);
  });
}
