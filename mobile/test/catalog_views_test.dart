import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/catalog_views.dart';
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

Future<void> chooseMode(WidgetTester tester, CatalogViewMode mode) async {
  await tester.tap(find.byKey(const Key('catalog-view-mode')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('catalog-view-${mode.name}')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a lista é o padrão e o menu oferece só lista e grade', (
    tester,
  ) async {
    await openCatalog(tester, [race('A', '2026-11-15')]);
    expect(find.byKey(const Key('catalog-grid')), findsNothing);
    await tester.tap(find.byKey(const Key('catalog-view-mode')));
    await tester.pumpAndSettle();
    expect(find.text('Lista'), findsOneWidget);
    expect(find.text('Grade'), findsOneWidget);
    expect(find.text('Calendário'), findsNothing);
  });

  testWidgets('grade: cartões em colunas e botão para escolher as colunas', (
    tester,
  ) async {
    await openCatalog(tester, [
      race('A', '2026-11-15'),
      race('B', '2026-12-06'),
    ]);
    await chooseMode(tester, CatalogViewMode.grid);
    expect(find.byKey(const Key('catalog-grid')), findsOneWidget);
    expect(find.byKey(const Key('grid-card-A')), findsOneWidget);
    expect(find.byKey(const Key('grid-card-B')), findsOneWidget);
    final two = tester.getSize(find.byKey(const Key('grid-card-A'))).width;
    await tester.tap(find.byKey(const Key('catalog-view-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('grid-columns-3')));
    await tester.pumpAndSettle();
    final three = tester.getSize(find.byKey(const Key('grid-card-A'))).width;
    expect(three, lessThan(two));
    final saved = await CatalogViewMode.read();
    expect(saved, CatalogViewMode.grid);
  });

  testWidgets('a escolha da grade fica guardada; valor antigo vira lista', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      CatalogViewMode.storageKey: 'grid',
    });
    await openCatalog(tester, [race('A', '2026-11-15')]);
    expect(find.byKey(const Key('catalog-grid')), findsOneWidget);
    SharedPreferences.setMockInitialValues({
      CatalogViewMode.storageKey: 'calendar',
    });
    expect(await CatalogViewMode.read(), CatalogViewMode.list);
  });
}
