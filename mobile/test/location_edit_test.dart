import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/my_races.dart';

Future<(IdentityGateway, List<Map<String, dynamic>?>)> setup({
  String? state,
  String? city,
}) async {
  final patches = <Map<String, dynamic>?>[];
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
      if (method == 'PATCH') {
        patches.add(body);
        return const JsonReply(200, {'id': 'u1', 'version': 4});
      }
      if (uri.path == '/me') {
        return JsonReply(200, {
          'id': 'u1',
          'displayName': 'Eu',
          'username': 'eu',
          'version': 3,
          'state': ?state,
          'city': ?city,
        });
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return (gateway, patches);
}

void main() {
  testWidgets(
    'Editar perfil sem estado/cidade convida a preencher e salva a escolha',
    (tester) async {
      final (gateway, patches) = await setup();
      await tester.pumpWidget(
        MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Toque para informar seu estado e cidade'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('edit-profile')));
      await tester.pumpAndSettle();
      // Aceita o primeiro da lista (Acre/Acrelândia).
      await tester.tap(find.byKey(const Key('location-done')));
      await tester.pumpAndSettle();
      expect(patches, [
        {
          'expectedVersion': 3,
          'state': 'AC',
          'city': 'Acrelândia',
          'latitude': -9.82581,
          'longitude': -66.8972,
        },
      ]);
    },
  );

  testWidgets('Editar perfil com estado/cidade salvos mostra "UF - Cidade"', (
    tester,
  ) async {
    final (gateway, _) = await setup(state: 'SP', city: 'Taboão da Serra');
    await tester.pumpWidget(
      MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    expect(find.text('SP - Taboão da Serra'), findsOneWidget);
  });
}
