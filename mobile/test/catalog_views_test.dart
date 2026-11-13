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

  test('editionDay só aceita datas de calendário válidas', () {
    expect(editionDay({'date': '2026-11-15'}), DateTime(2026, 11, 15));
    expect(editionDay({'date': '2026-02-31'}), isNull);
    expect(editionDay({'date': '15/11/2026'}), isNull);
    expect(editionDay({}), isNull);
  });

  testWidgets('a lista é o padrão e o menu oferece lista, grade e calendário', (
    tester,
  ) async {
    await openCatalog(tester, [race('A', '2026-11-15')]);
    expect(find.byKey(const Key('catalog-grid')), findsNothing);
    expect(find.byKey(const Key('catalog-calendar')), findsNothing);
    await tester.tap(find.byKey(const Key('catalog-view-mode')));
    await tester.pumpAndSettle();
    expect(find.text('Lista'), findsOneWidget);
    expect(find.text('Grade'), findsOneWidget);
    expect(find.text('Calendário'), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('grid-columns')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('grid-columns-3')));
    await tester.pumpAndSettle();
    final three = tester.getSize(find.byKey(const Key('grid-card-A'))).width;
    expect(three, lessThan(two));
    final saved = await CatalogViewMode.read();
    expect(saved, CatalogViewMode.grid);
  });

  testWidgets('calendário: cada corrida só aparece no dia da sua data', (
    tester,
  ) async {
    await openCatalog(tester, [
      race('A', '2026-11-15'),
      race('B', '2026-11-22'),
      race('C', '2026-12-06'),
    ]);
    await chooseMode(tester, CatalogViewMode.calendar);
    expect(find.byKey(const Key('catalog-calendar')), findsOneWidget);
    // Hoje não tem corrida: abre no mês da corrida mais próxima (novembro de 2026).
    expect(find.text('novembro de 2026'), findsOneWidget);
    expect(find.text('Corridas de novembro'), findsOneWidget);
    expect(find.text('[FICTICIA] Corrida A'), findsOneWidget);
    expect(find.text('[FICTICIA] Corrida B'), findsOneWidget);
    expect(find.text('[FICTICIA] Corrida C'), findsNothing);
    // Tocar no dia 15 mostra só a corrida desse dia.
    await tester.tap(find.byKey(const Key('catalog-day-2026-11-15')));
    await tester.pumpAndSettle();
    expect(find.text('15 de novembro'), findsOneWidget);
    expect(find.text('[FICTICIA] Corrida A'), findsOneWidget);
    expect(find.text('[FICTICIA] Corrida B'), findsNothing);
    // Dia sem corrida não é tocável.
    final empty = tester.widget<InkWell>(
      find.byKey(const Key('catalog-day-2026-11-16')),
    );
    expect(empty.onTap, isNull);
    // Mês seguinte: só a corrida de dezembro.
    await tester.tap(find.byKey(const Key('catalog-cal-next')));
    await tester.pumpAndSettle();
    expect(find.text('dezembro de 2026'), findsOneWidget);
    expect(find.text('[FICTICIA] Corrida C'), findsOneWidget);
    expect(find.text('[FICTICIA] Corrida A'), findsNothing);
  });

  testWidgets('a escolha da visualização fica guardada', (tester) async {
    SharedPreferences.setMockInitialValues({
      CatalogViewMode.storageKey: 'calendar',
    });
    await openCatalog(tester, [race('A', '2026-11-15')]);
    expect(find.byKey(const Key('catalog-calendar')), findsOneWidget);
  });
}
