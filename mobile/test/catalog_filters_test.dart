import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/catalog_filters.dart';

import 'catalog_test.dart' show entry, signed;

/// Corrida [FICTICIA] numa cidade de SP, daqui a alguns meses (sempre no futuro).
Map<String, dynamic> race(String id, String city) {
  final day = DateTime.now().add(const Duration(days: 40));
  final iso =
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
  return {...entry(id), 'name': '[FICTICIA] $id', 'city': city, 'date': iso};
}

Future<List<Map<String, String>>> open(
  WidgetTester tester,
  List<Map<String, dynamic>> editions, {
  String city = 'São Paulo',
}) async {
  tester.view.physicalSize = const Size(800, 40000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final calls = <Map<String, String>>[];
  final gateway = await signed((uri, method, headers, body) async {
    if (uri.path == '/me') {
      return JsonReply(200, {'city': city, 'state': 'SP', 'version': 1});
    }
    if (uri.path == '/editions') {
      calls.add(uri.queryParameters);
      return JsonReply(200, {'items': editions});
    }
    return const JsonReply(200, {'items': []});
  });
  await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
  await tester.pumpAndSettle();
  return calls;
}

bool shown(String id) => find
    .byKey(Key('compact-card-$id'), skipOffstage: false)
    .evaluate()
    .isNotEmpty;

void main() {
  testWidgets(
    'abre com "Perto de mim": só as corridas até 50 km da cidade do perfil',
    (tester) async {
      final calls = await open(tester, [
        race('sp', 'São Paulo'),
        race('sa', 'Santo André'), // ~20 km
        race('gu', 'Guarulhos'), // ~15 km
        race('ca', 'Campinas'), // ~85 km: fora
        race('sv', 'Santos'), // ~60 km: fora
        race('xx', 'Cidade Que Não Existe'), // sem coordenada: não entra
      ]);
      expect(shown('sp'), isTrue);
      expect(shown('sa'), isTrue);
      expect(shown('gu'), isTrue);
      expect(shown('ca'), isFalse);
      expect(shown('sv'), isFalse);
      expect(shown('xx'), isFalse);
      // O servidor recebe o estado e as corridas de hoje em diante; o raio é conferido no app.
      expect(calls.first['state'], 'SP');
      expect(calls.first.containsKey('city'), isFalse);
      expect(calls.first.containsKey('dateFrom'), isTrue);
      // "Perto de mim" é o padrão: a pílula aparece sem destaque.
      expect(find.text('Perto de mim'), findsOneWidget);
      expect(
        tester
            .widget<FilterPill>(find.byKey(const Key('filter-near-me')))
            .active,
        isFalse,
      );
    },
  );

  testWidgets('mostra 20 por vez e "Carregar mais" traz as próximas', (
    tester,
  ) async {
    final calls = await open(tester, [
      for (var i = 0; i < 45; i++) race('r$i', 'São Paulo'),
    ]);
    expect(
      [
        for (var i = 0; i < 45; i++)
          if (shown('r$i')) i,
      ].length,
      20,
    );
    expect(calls, hasLength(1));
    await tester.ensureVisible(find.byKey(const Key('catalog-show-more')));
    await tester.tap(find.byKey(const Key('catalog-show-more')));
    await tester.pumpAndSettle();
    expect(
      [
        for (var i = 0; i < 45; i++)
          if (shown('r$i')) i,
      ].length,
      40,
    );
    expect(calls, hasLength(1)); // a fila bastou: sem nova chamada
    await tester.ensureVisible(find.byKey(const Key('catalog-show-more')));
    await tester.tap(find.byKey(const Key('catalog-show-more')));
    await tester.pumpAndSettle();
    expect(
      [
        for (var i = 0; i < 45; i++)
          if (shown('r$i')) i,
      ].length,
      45,
    );
    expect(find.byKey(const Key('catalog-show-more')), findsNothing);
  });

  testWidgets('sem corrida no raio, explica e dá o caminho', (tester) async {
    await open(tester, [race('ca', 'Campinas')]);
    expect(shown('ca'), isFalse);
    expect(find.byKey(const Key('catalog-empty')), findsOneWidget);
    expect(find.textContaining('50 km'), findsWidgets);
  });

  testWidgets('tocar "Perto de mim" amplia para qualquer distância', (
    tester,
  ) async {
    final calls = await open(tester, [
      race('sp', 'São Paulo'),
      race('ca', 'Campinas'),
    ]);
    expect(shown('ca'), isFalse);
    await tester.tap(find.byKey(const Key('filter-near-me')));
    await tester.pumpAndSettle();
    expect(shown('sp'), isTrue);
    expect(shown('ca'), isTrue);
    // Ampliada: a pílula fica em destaque como "Qualquer distância"; o × volta ao padrão.
    expect(find.text('Qualquer distância'), findsOneWidget);
    expect(calls.last.containsKey('state'), isFalse);
  });

  testWidgets('filtro por ano pede o ano inteiro ao servidor', (tester) async {
    final calls = await open(tester, [race('sp', 'São Paulo')]);
    final next = DateTime.now().year + 1;
    await tester.tap(find.byKey(const Key('filter-year')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('year-option-$next')));
    await tester.pumpAndSettle();
    expect(calls.last['dateFrom'], '$next-01-01');
    expect(calls.last['dateTo'], '$next-12-31');
    expect(find.text('$next'), findsOneWidget); // a pílula mostra o ano
    // O × da pílula tira o ano.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('filter-year')),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls.last.containsKey('dateTo'), isFalse);
    expect(find.text('Ano'), findsOneWidget);
  });

  testWidgets(
    'filtro por localização usa a cidade escolhida e desliga "perto de mim"',
    (tester) async {
      final calls = await open(tester, [race('sp', 'São Paulo')]);
      await tester.tap(find.byKey(const Key('filter-location')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('location-done')),
      ); // primeira da lista
      await tester.pumpAndSettle();
      expect(calls.last['state'], 'AC');
      expect(calls.last['city'], 'Acrelândia');
      expect(find.text('Perto de mim'), findsOneWidget); // desligado
      expect(
        find.text('Acrelândia'),
        findsOneWidget,
      ); // a pílula mostra a cidade
      // Ligar "perto de mim" de novo tira a localização.
      await tester.tap(find.byKey(const Key('filter-near-me')));
      await tester.pumpAndSettle();
      expect(calls.last['state'], 'SP');
      expect(calls.last.containsKey('city'), isFalse);
      expect(find.text('Localização'), findsOneWidget);
    },
  );

  testWidgets(
    'cidade do perfil sem coordenada conhecida: filtra só por ela, como antes',
    (tester) async {
      final calls = await open(tester, [
        race('x', 'Cidade Que Não Existe'),
      ], city: 'Cidade Que Não Existe');
      expect(calls.first['city'], 'Cidade Que Não Existe');
      expect(find.text('Perto de mim'), findsOneWidget); // desligado
    },
  );

  testWidgets(
    'com busca por nome, as pílulas ficam apagadas e a busca vale para tudo',
    (tester) async {
      final calls = await open(tester, [race('sp', 'São Paulo')]);
      await tester.enterText(
        find.byKey(const Key('catalog-name-search')),
        'meia',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(calls.last, {'q': 'meia', 'limit': '20'});
      final pills = tester.widget<Opacity>(
        find.ancestor(
          of: find.byKey(const Key('catalog-filter-pills')),
          matching: find.byType(Opacity),
        ),
      );
      expect(pills.opacity, lessThan(1));
    },
  );
}
