import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/my_races.dart';

Map<String, dynamic> plan(String id, String status, String date) => {
  'editionId': id,
  'status': status,
  'edition': {
    'id': id,
    'name': '[FICTICIA] Corrida $id',
    'date': date,
    'city': 'São Paulo',
    'state': 'SP',
  },
};

Future<IdentityGateway> gatewayWith(List<Map<String, dynamic>> plans) async {
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
          'id': 'u1',
          'displayName': 'Corredor Teste',
          'username': 'corredor_teste',
          'version': 1,
        });
      }
      if (uri.path == '/me/race-plans') {
        return JsonReply(200, {'items': plans});
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return gateway;
}

void main() {
  testWidgets(
    'Quero correr mostra desejadas e inscritas da agenda, 3 por linha',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await gatewayWith([
        plan('d', 'wanted', '2027-04-10'),
        plan('a', 'wanted', '2027-01-10'),
        plan('b', 'wanted', '2027-02-10'),
        plan('c', 'wanted', '2027-03-10'),
        plan('r', 'registered', '2027-05-10'),
      ]);
      await tester.pumpWidget(
        MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no-plans')), findsNothing);
      expect(find.text('Desejadas'), findsOneWidget);
      expect(find.text('Inscritas'), findsOneWidget);
      Offset at(String id) =>
          tester.getTopLeft(find.byKey(Key('plan-$id'), skipOffstage: false));
      // Da mais proxima para a mais distante: a, b, c na 1a linha; d na 2a.
      expect(at('a').dy, at('b').dy);
      expect(at('b').dy, at('c').dy);
      expect(at('a').dx, lessThan(at('b').dx));
      expect(at('b').dx, lessThan(at('c').dx));
      expect(at('d').dy, greaterThan(at('a').dy));
      expect(
        find.byKey(const Key('plan-r'), skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('Ver agenda'), findsOneWidget);
      // Mesmo degradê dos cards de corrida do catálogo.
      expect(
        find.byKey(const Key('race-art'), skipOffstage: false),
        findsNWidgets(5),
      );
    },
  );

  testWidgets(
    'com barra de status, o título fica colado nos cards (sem padding extra)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await gatewayWith([plan('a', 'wanted', '2027-01-10')]);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(padding: EdgeInsets.only(top: 60)),
            child: RunnerProfileScreen(gateway: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final label = tester.getBottomLeft(find.text('Desejadas')).dy;
      final tile = tester.getTopLeft(find.byKey(const Key('plan-a'))).dy;
      expect(tile - label, lessThan(12));
    },
  );

  testWidgets('sem corridas na agenda aparece a mensagem de vazio', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await gatewayWith(const []);
    await tester.pumpWidget(
      MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('no-plans')), findsOneWidget);
  });
}
