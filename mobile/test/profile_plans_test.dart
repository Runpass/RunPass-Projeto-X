import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    'Quero correr mostra desejadas e inscritas da agenda, uma por linha',
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
      // Título com "Ver todas" (leva à agenda); as inscritas num subtítulo.
      expect(find.text('Quero correr'), findsOneWidget);
      expect(find.text('Ver todas'), findsOneWidget);
      expect(find.text('Desejadas'), findsNothing);
      expect(find.text('Inscritas'), findsOneWidget);
      Offset at(String id) =>
          tester.getTopLeft(find.byKey(Key('plan-$id'), skipOffstage: false));
      // Em linha: da mais próxima para a mais distante, uma por linha, só as 3 primeiras.
      expect(at('b').dy, greaterThan(at('a').dy));
      expect(at('c').dy, greaterThan(at('b').dy));
      expect(at('a').dx, at('b').dx);
      expect(
        find.byKey(const Key('plan-d'), skipOffstage: false),
        findsNothing,
      ); // a quarta fica em "Ver todas"
      expect(
        find.byKey(const Key('plan-r'), skipOffstage: false),
        findsOneWidget,
      );
      // Cada "Quero correr" tem o coração que tira da lista; a inscrita, não.
      for (final id in ['a', 'b', 'c']) {
        expect(find.byKey(Key('plan-heart-$id')), findsOneWidget);
      }
      expect(find.byKey(const Key('plan-heart-r')), findsNothing);
      // Cada linha mostra a data por extenso e o local.
      expect(find.text('10 de janeiro de 2027'), findsOneWidget);
      expect(find.text('São Paulo, SP'), findsNWidgets(4));
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
      final label = tester.getBottomLeft(find.text('Quero correr')).dy;
      final tile = tester.getTopLeft(find.byKey(const Key('plan-a'))).dy;
      expect(tile - label, lessThan(12));
    },
  );

  test('selos: todos existem e só os conquistados saem do bloqueio', () {
    final none = sealsOf(const RaceStats(0, 0, {}));
    expect(none.map((s) => s.label), [
      'Desbravador',
      '5K',
      '10K',
      '21K',
      '42K',
    ]);
    expect(none.every((s) => !s.earned), isTrue);

    final some = sealsOf(RaceStats(3, 2, {5.0: 2, 21.0: 1}));
    expect(
      {for (final s in some) s.label: s.earned},
      {
        'Desbravador': true,
        '5K': true,
        '10K': false,
        '21K': true,
        '42K': false,
      },
    );
    expect(some.map((s) => s.item.title), [
      'Desbravador',
      'Primeiro Passo',
      'Ritmo Forte',
      'Meio Caminho',
      'Lenda da Maratona',
    ]);
  });

  testWidgets(
    'perfil mostra todos os selos entre o nome e o @usuario, bloqueados '
    'quando ainda não conquistados',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await gatewayWith(const []);
      await tester.pumpWidget(
        MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      for (final label in ['Desbravador', '5K', '10K', '21K', '42K']) {
        expect(find.byKey(Key('seal-$label')), findsOneWidget);
        expect(find.byKey(Key('seal-locked-$label')), findsOneWidget);
      }
      final name = tester.getBottomLeft(find.text('Corredor Teste')).dy;
      final seals = tester.getTopLeft(find.byKey(const Key('seal-row'))).dy;
      final handle = tester
          .getTopLeft(find.textContaining('@corredor_teste'))
          .dy;
      expect(seals, greaterThan(name - 1));
      expect(handle, greaterThan(seals));
      await tester.tap(find.byKey(const Key('seal-5K')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('achievements-sheet')), findsOneWidget);
      expect(
        find.textContaining('Bloqueado. Conclua uma prova de 5K.'),
        findsOneWidget,
      );
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

  testWidgets(
    'perfil: Quero correr é só lista; Minhas publicações sempre em grade de 3',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await gatewayWith([plan('a', 'wanted', '2027-01-10')]);
      await tester.pumpWidget(
        MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('view-menu-plans')), findsNothing);
      expect(
        find.byKey(const Key('view-menu-posts')),
        findsNothing,
      ); // publicações: sempre grade de 3
      expect(find.byKey(const Key('plan-row-a')), findsOneWidget);
    },
  );
}
