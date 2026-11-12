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

  testWidgets('escolher o número de colunas muda a grade da agenda e vale '
      'depois de reabrir', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await gatewayWith([
      plan('a', 'wanted', '2027-01-10'),
      plan('b', 'wanted', '2027-02-10'),
      plan('c', 'wanted', '2027-03-10'),
      plan('d', 'wanted', '2027-04-10'),
    ]);
    Future<void> openProfile() async {
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: RunnerProfileScreen(gateway: gateway),
        ),
      );
      await tester.pumpAndSettle();
    }

    double top(String id) =>
        tester.getTopLeft(find.byKey(Key('plan-$id'), skipOffstage: false)).dy;
    await openProfile();
    expect(top('a'), top('c')); // padrão: 3 por linha
    expect(top('d'), greaterThan(top('a')));

    await tester.tap(find.byKey(const Key('grid-columns-plans')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('grid-columns-2')));
    await tester.pumpAndSettle();
    expect(top('a'), top('b')); // agora 2 por linha
    expect(top('c'), greaterThan(top('a')));

    await openProfile(); // reabrir: a escolha ficou guardada
    expect(top('a'), top('b'));
    expect(top('c'), greaterThan(top('a')));
  });

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
