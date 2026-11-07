import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/notifications.dart';
import 'package:runpass/runpass_theme.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'Aceitar e Recusar aparecem e sao tocaveis com o tema REAL do app (${dark ? 'escuro' : 'claro'})',
      (tester) async {
        final calls = <String>[];
        final gateway = IdentityGateway(
          cognito: Uri.parse('https://cognito.example'),
          api: Uri.parse('https://api.example'),
          clientId: 'synthetic',
          transport: (uri, method, headers, body) async {
            if (uri.host == 'cognito.example') {
              return const JsonReply(200, {
                'AuthenticationResult': {'AccessToken': 'a'},
              });
            }
            calls.add('$method ${uri.path}');
            if (uri.path == '/me/notifications') {
              return const JsonReply(200, {
                'unreadCount': 1,
                'items': [
                  {
                    'id': 'follow_request:b::x',
                    'kind': 'follow_request',
                    'createdAt': '2026-11-06T10:00:00Z',
                    'unread': true,
                    'actor': {
                      'id': 'bia',
                      'displayName': 'Bia',
                      'username': 'bia',
                    },
                  },
                ],
              });
            }
            return const JsonReply(200, {
              'profileId': 'bia',
              'state': 'active',
            });
          },
        );
        await gateway.signIn('a@x.test', 's');
        await tester.pumpWidget(
          MaterialApp(
            theme: runPassTheme(),
            darkTheme: runPassDarkTheme(),
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            home: NotificationsScreen(gateway: gateway),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull); // sem erro de layout
        final approve = find.byKey(const Key('notification-approve-bia'));
        expect(approve, findsOneWidget);
        final size = tester.getSize(approve);
        expect(size.width, lessThan(400)); // largura finita e visivel
        expect(size.width, greaterThan(40));
        await tester.tap(approve);
        await tester.pumpAndSettle();
        expect(calls, contains('PUT /me/follow-requests/bia'));
      },
    );
  }
}
