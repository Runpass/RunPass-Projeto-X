import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/medal_scan.dart' show readableMedalName;

// Dados [FICTICIA]. A prateleira de medalhas nao pode mudar de ordem, de nome nem de total so porque
// o servidor recusou algumas das chamadas simultaneas (cota de execucoes da conta do DEV).

Map<String, dynamic> edition(String id, String date, num km) => {
  'id': id,
  'name': 'Corrida $id',
  'date': date,
  'city': 'São Paulo',
  'state': 'SP',
  'status': 'past',
  'version': 1,
  'distances': [
    {'id': 'd', 'kilometers': km},
  ],
};

Map<String, dynamic> done(String id, String editionId, String completedAt) => {
  'id': id,
  'editionId': editionId,
  'distanceId': 'd',
  'state': 'completed',
  'version': 2,
  'completedAt': completedAt,
};

class Harness {
  final Map<String, Map<String, dynamic>> editions;
  List<Map<String, dynamic>> participations;
  final calls = <String, int>{};
  var inFlight = 0, maxInFlight = 0;

  /// Quantas respostas SERVICE_UNAVAILABLE por corrida antes de responder bem.
  final failures = <String, int>{};
  Duration latency = Duration.zero;
  bool embed = false; // servidor novo: devolve a corrida junto da participacao (expand=edition)
  final listQueries = <Map<String, String>>[];

  Harness(this.editions, this.participations);

  late final IdentityGateway gateway = IdentityGateway(
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
        listQueries.add(uri.queryParameters);
        final embedEditions =
            embed && uri.queryParameters['expand'] == 'edition';
        return JsonReply(200, {
          'items': [
            for (final p in participations)
              {
                ...p,
                if (embedEditions && editions[p['editionId']] != null)
                  'edition': editions[p['editionId']],
              },
          ],
        });
      }
      if (uri.path == '/me/edition-requests') {
        return const JsonReply(200, {'items': []});
      }
      if (uri.path == '/me') {
        return const JsonReply(200, {'displayName': 'Teste', 'version': 1});
      }
      final id = uri.pathSegments.last;
      if (uri.path.startsWith('/editions/')) {
        calls[id] = (calls[id] ?? 0) + 1;
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        if (latency > Duration.zero) await Future<void>.delayed(latency);
        inFlight--;
        final left = failures[id] ?? 0;
        if (left > 0) {
          failures[id] = left - 1;
          return const JsonReply(503, {'code': 'SERVICE_UNAVAILABLE'});
        }
        final match = editions[id];
        return match == null
            ? const JsonReply(404, {'code': 'EDITION_NOT_FOUND'})
            : JsonReply(200, match);
      }
      return const JsonReply(404, {'code': 'NOT_FOUND'});
    },
  );

  Future<IdentityGateway> signedIn() async {
    await gateway.signIn('synthetic@example.test', 'synthetic');
    return gateway;
  }
}

void main() {
  test('carrega as corridas em no maximo 4 chamadas por vez', () async {
    final ids = [for (var i = 0; i < 12; i++) 'e$i'];
    final h = Harness({
      for (final id in ids) id: edition(id, '2026-01-01', 5),
    }, [])..latency = const Duration(milliseconds: 20);
    final found = await loadEditions(await h.signedIn(), ids);
    expect(found.length, 12);
    expect(h.maxInFlight, lessThanOrEqualTo(4));
  });

  test(
    'falha passageira (503) tenta de novo e recupera; 404 nao repete',
    () async {
      final h = Harness({'a': edition('a', '2026-01-01', 5)}, []);
      h.failures['a'] = 2;
      final gateway = await h.signedIn();
      final found = await loadEditions(gateway, ['a', 'ausente']);
      expect(found['a']?['name'], 'Corrida a');
      expect(h.calls['a'], 3);
      expect(found.containsKey('ausente'), isFalse);
      expect(h.calls['ausente'], 1);
    },
  );

  test('desiste depois de 3 tentativas e deixa a corrida de fora', () async {
    final h = Harness({'a': edition('a', '2026-01-01', 5)}, []);
    h.failures['a'] = 10;
    final found = await loadEditions(await h.signedIn(), ['a']);
    expect(found, isEmpty);
    expect(h.calls['a'], 3);
  });

  test('guarda a corrida: a volta a prateleira nao pergunta de novo', () async {
    final h = Harness({'a': edition('a', '2026-01-01', 5)}, []);
    final gateway = await h.signedIn();
    await loadEditions(gateway, ['a']);
    h.failures['a'] = 10; // mesmo que o servidor passe a falhar...
    final again = await loadEditions(gateway, ['a']);
    expect(again['a']?['name'], 'Corrida a'); // ...o dado guardado vale
    expect(h.calls['a'], 1);
  });

  test(
    'mesma data: desempata por conclusao e id, em qualquer ordem de resposta',
    () async {
      final eds = {'a': edition('a', '2026-03-10', 5)};
      final p1 = done('p1', 'a', '2026-03-11T10:00:00Z');
      final p2 = done('p2', 'a', '2026-03-11T12:00:00Z');
      final p3 = done('p3', 'a', '2026-03-11T12:00:00Z');
      final h = Harness(eds, [p1, p2, p3]);
      final gateway = await h.signedIn();
      final first = (await loadMyRaces(gateway))
          .map((r) => r.participation['id'])
          .toList();
      h.participations = [p3, p1, p2];
      clearMedalCaches();
      final second = (await loadMyRaces(gateway))
          .map((r) => r.participation['id'])
          .toList();
      expect(first, ['p2', 'p3', 'p1']);
      expect(second, first);
    },
  );

  testWidgets(
    'corrida que nao carregou avisa que os totais podem estar incompletos e tenta de novo',
    (tester) async {
      final h = Harness(
        {
          'a': edition('a', '2026-03-10', 5),
          'b': edition('b', '2026-04-10', 10),
        },
        [
          done('p1', 'a', '2026-03-11T10:00:00Z'),
          done('p2', 'b', '2026-04-11T10:00:00Z'),
        ],
      );
      h.failures['b'] = 3; // as 3 tentativas falham
      final gateway = await h.signedIn();
      await tester.pumpWidget(
        MaterialApp(home: MedalCollectionScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('medals-incomplete')), findsOneWidget);
      expect(
        find.textContaining('Uma corrida não carregou agora'),
        findsOneWidget,
      );
      expect(
        find.text('5'),
        findsOneWidget,
      ); // so a corrida que chegou entra nos km
      h.failures['b'] = 0;
      await tester.ensureVisible(find.byKey(const Key('medals-retry')));
      await tester.tap(find.byKey(const Key('medals-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('medals-incomplete')), findsNothing);
      expect(find.text('15'), findsOneWidget); // 5 + 10 km
    },
  );

  testWidgets('filtro e ordem escolhidos continuam ao sair da aba e voltar', (
    tester,
  ) async {
    final h = Harness(
      {'a': edition('a', '2026-03-10', 5)},
      [done('p1', 'a', '2026-03-11T10:00:00Z')],
    );
    final gateway = await h.signedIn();
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(key: UniqueKey(), gateway: gateway),
        ),
      );
      await tester.pumpAndSettle();
    }

    bool selected(String label) => tester
        .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
        .selected;

    await open();
    expect(selected('Todas'), isTrue);
    await tester.tap(find.text('Por ano'));
    // Só o ícone de ordem, sem texto; a dica diz a ordem atual.
    expect(find.text('Corridas mais recentes'), findsNothing);
    expect(find.byTooltip('Corridas mais recentes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('medal-sort')));
    await tester.pumpAndSettle();
    await open(); // a tela e recriada ao trocar de aba
    expect(selected('Por ano'), isTrue);
    expect(find.byTooltip('Corridas mais antigas'), findsOneWidget);
    expect(find.text('Corridas mais antigas'), findsNothing);
  });

  testWidgets('sem medalhas, so existe o botao grande de adicionar', (
    tester,
  ) async {
    final h = Harness({}, []);
    await tester.pumpWidget(
      MaterialApp(home: MedalCollectionScreen(gateway: await h.signedIn())),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('medal-add-first')), findsOneWidget);
    expect(find.byKey(const Key('medal-add-tile')), findsNothing);
  });

  testWidgets('com medalhas, o "+" ao lado do titulo continua', (tester) async {
    final h = Harness(
      {'a': edition('a', '2026-03-10', 5)},
      [done('p1', 'a', '2026-03-11T10:00:00Z')],
    );
    await tester.pumpWidget(
      MaterialApp(home: MedalCollectionScreen(gateway: await h.signedIn())),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('medal-add-tile')), findsOneWidget);
  });

  test('servidor novo: a corrida vem junto da participacao, sem uma chamada por medalha', () async {
    final h = Harness(
      {'a': edition('a', '2026-03-10', 5), 'b': edition('b', '2026-04-10', 10)},
      [
        done('p1', 'a', '2026-03-11T10:00:00Z'),
        done('p2', 'b', '2026-04-11T10:00:00Z'),
      ],
    )..embed = true;
    final races = await loadMyRaces(await h.signedIn());
    expect(races.map((r) => r.name), ['Corrida b', 'Corrida a']);
    expect(h.listQueries.single['expand'], 'edition');
    expect(h.calls, isEmpty); // nenhum GET /editions/{id}
    expect(races.first.participation.containsKey('edition'), isFalse);
  });

  test('servidor antigo (ignora expand): o app busca as corridas uma a uma, como antes', () async {
    final h = Harness(
      {'a': edition('a', '2026-03-10', 5)},
      [done('p1', 'a', '2026-03-11T10:00:00Z')],
    );
    final races = await loadMyRaces(await h.signedIn());
    expect(races.single.name, 'Corrida a');
    expect(h.calls['a'], 1);
  });

  test(
    'nome da medalha em caixa alta fica legivel (T10); o resto nao muda',
    () {
      expect(
        readableMedalName('MARATONA FANTASMA DO VALE'),
        'Maratona Fantasma do Vale',
      );
      expect(
        readableMedalName('29ª MARATONA INTERNACIONAL DE SÃO PAULO'),
        '29ª Maratona Internacional de São Paulo',
      );
      expect(
        readableMedalName('CORRIDA 10K DA CIDADE'),
        'Corrida 10K da Cidade',
      );
      expect(
        readableMedalName('Maratona Pão de Açúcar'),
        'Maratona Pão de Açúcar',
      );
      expect(
        readableMedalName('TESTE QA CORRIDA JORNADA'),
        'Teste QA Corrida Jornada',
      );
      expect(readableMedalName('MEIA DO RIO SP'), 'Meia do Rio SP');
      expect(readableMedalName('maratona do rio'), 'maratona do rio');
      expect(readableMedalName(''), '');
    },
  );
}
