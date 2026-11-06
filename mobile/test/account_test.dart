import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/my_races.dart';
import 'package:runpass/settings.dart';

Future<(IdentityGateway, List<String>)> profileGateway() async {
  final calls = <String>[];
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
      calls.add('$method ${uri.path}');
      if (method == 'DELETE') return const JsonReply(202, {});
      if (uri.path == '/me') {
        return const JsonReply(200, {
          'id': 'u1',
          'displayName': 'Corredor Teste',
          'username': 'corredor_teste',
        });
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return (gateway, calls);
}

Future<void> openProfile(WidgetTester tester, IdentityGateway gateway) async {
  await tester.pumpWidget(
    MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
  );
  await tester.pumpAndSettle();
  // Sair, excluir conta e privacidade ficam nas configuracoes (engrenagem).
  await tester.tap(find.byKey(const Key('open-settings')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Sair in settings ends the session and returns to sign in', (
    tester,
  ) async {
    final (gateway, _) = await profileGateway();
    await openProfile(tester, gateway);
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    expect(gateway.signedIn, isFalse);
    expect(find.text('Entre no RunPass'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('Excluir minha conta confirms, deletes and signs out', (
    tester,
  ) async {
    final (gateway, calls) = await profileGateway();
    await openProfile(tester, gateway);
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();
    expect(find.text('Excluir sua conta?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Excluir minha conta'));
    await tester.pumpAndSettle();
    expect(calls, contains('DELETE /me'));
    expect(gateway.signedIn, isFalse);
    expect(find.text('Entre no RunPass'), findsOneWidget);
    expect(
      find.text('Exclusão aceita. O acesso à conta foi encerrado.'),
      findsOneWidget,
    );
  });

  testWidgets('Cancelar keeps the account and the session', (tester) async {
    final (gateway, calls) = await profileGateway();
    await openProfile(tester, gateway);
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('DELETE /me')));
    expect(gateway.signedIn, isTrue);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
