import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> race(String id, String date) => {
  'id': id,
  'name': '[FICTICIA] Corrida $id',
  'date': date,
  'city': 'São Paulo',
  'state': 'SP',
  'status': 'upcoming',
  'version': 1,
  'distances': [
    {'id': '10k', 'kilometers': 10},
  ],
};

Future<IdentityGateway> gateway(List<Map<String, dynamic>> editions) async {
  final g = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      if (uri.path == '/editions') {
        return JsonReply(200, {'items': editions});
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await g.signIn('synthetic@example.test', 'synthetic');
  return g;
}

Future<void> openCatalog(
  WidgetTester tester,
  List<Map<String, dynamic>> editions,
) async {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: CatalogScreen(gateway: await gateway(editions))),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Corridas mostra só a lista: sem opção de grade nem filtro de data',
    (tester) async {
      await openCatalog(tester, [race('A', '2026-12-06')]);
      expect(find.byKey(const Key('catalog-view-mode')), findsNothing);
      expect(find.byKey(const Key('catalog-grid')), findsNothing);
      expect(find.byKey(const Key('catalog-date-filter')), findsNothing);
      expect(find.byKey(const Key('compact-card-A')), findsOneWidget);
    },
  );
}
