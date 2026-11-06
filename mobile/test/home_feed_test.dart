import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/identity_gateway.dart';

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
    },
  );
}
