import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/br_locations.dart';
import 'package:runpass/demo_transport.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/location_picker.dart';
import 'package:runpass/my_races.dart';

// Dados [FICTICIA]. Ajustes da jornada: rascunho à vista na prateleira, aviso da conquista,
// busca de cidade no seletor e a parte social da demonstração.

Future<IdentityGateway> gatewayWith(List<Map<String, dynamic>> items) async {
  final gateway = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    byteTransport: (uri, method, headers, bytes) async => 200,
    sleeper: (_) async {},
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      if (uri.path == '/me/participations') {
        final state = uri.queryParameters['state'];
        return JsonReply(200, {
          'items': [
            for (final p in items)
              if (state == null || p['state'] == state) p,
          ],
        });
      }
      if (uri.path == '/me/edition-requests') {
        return const JsonReply(200, {'items': []});
      }
      if (uri.path == '/me') {
        return const JsonReply(200, {'displayName': 'Teste', 'version': 1});
      }
      return const JsonReply(404, {'code': 'NOT_FOUND'});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return gateway;
}

Map<String, dynamic> draft(String id, String name, String date) => {
  'id': id,
  'editionId': 'e-$id',
  'distanceId': 'd',
  'state': 'draft',
  'version': 1,
  'edition': {
    'id': 'e-$id',
    'name': name,
    'date': date,
    'city': 'São Paulo',
    'state': 'SP',
    'status': 'past',
    'version': 1,
    'distances': [
      {'id': 'd', 'kilometers': 5},
    ],
  },
};

void main() {
  testWidgets(
    'prateleira mostra o rascunho de corrida passada e o aviso da conquista',
    (tester) async {
      final gateway = await gatewayWith([
        draft('p1', 'Corrida Passada', '2025-01-10'),
        draft('p2', 'Corrida Futura', '2999-01-10'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            justEarned: 'Corrida Nova',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('medal-earned-banner')), findsOneWidget);
      expect(find.text('Corrida Nova entrou na sua coleção.'), findsOneWidget);
      // Só a corrida que já aconteceu entra em "Para concluir"; a futura fica na agenda.
      expect(find.byKey(const Key('medal-draft-p1')), findsOneWidget);
      expect(find.text('Corrida Passada'), findsOneWidget);
      expect(find.byKey(const Key('medal-draft-p2')), findsNothing);
      await tester.tap(find.byTooltip('Fechar'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('medal-earned-banner')), findsNothing);
    },
  );

  testWidgets('prateleira sem rascunho não mostra a faixa "Para concluir"', (
    tester,
  ) async {
    final gateway = await gatewayWith(const []);
    await tester.pumpWidget(
      MaterialApp(home: MedalCollectionScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('medal-drafts')), findsNothing);
    expect(find.byKey(const Key('medal-earned-banner')), findsNothing);
  });

  test('busca de cidade ignora acento e prefere o estado atual', () {
    final sp = brStates.indexWhere((s) => s.uf == 'SP');
    final found = findBrCity('sao paulo', preferUf: sp)!;
    expect(found.$1, sp);
    expect(brCitiesByState['SP']![found.$2], 'São Paulo');
    final other = findBrCity('Acrelandia', preferUf: sp)!;
    expect(brStates[other.$1].uf, 'AC');
    expect(findBrCity('a'), isNull); // curto demais
    expect(findBrCity('cidadequenaoexiste'), isNull);
  });

  testWidgets('seletor de cidade: digitar leva as rodas até a cidade', (
    tester,
  ) async {
    (String, String, double?, double?)? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked = await pickBrLocation(context),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('location-search')),
      'campinas',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('location-done')));
    await tester.pumpAndSettle();
    expect(picked?.$1, 'SP');
    expect(picked?.$2, 'Campinas');
  });

  test(
    'demonstração: buscar, seguir e abrir perfil de corredor fictício',
    () async {
      final demo = DemoTransport();
      const email = 'medalhas@runpass.test';
      final found = demo.demoSocial(
        Uri.parse('https://demo/profiles?q=mariana'),
        'GET',
        email,
      )!;
      final card = (found.body['items'] as List).single as Map;
      expect(card['displayName'], 'Mariana Lopes');
      expect(card['followState'], 'none');
      demo.demoSocial(
        Uri.parse('https://demo/profiles/${card['id']}/follow'),
        'PUT',
        email,
      );
      final profile = demo.demoSocial(
        Uri.parse('https://demo/profiles/${card['id']}'),
        'GET',
        email,
      )!;
      expect(profile.body['followState'], 'active');
      expect(
        demo.demoSocial(Uri.parse('https://demo/editions/x'), 'GET', email),
        isNull,
      );
    },
  );
}
