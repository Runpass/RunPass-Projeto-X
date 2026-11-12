import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/agenda.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';

import 'catalog_test.dart' show entry, signed;

Map<String, dynamic> upcoming(String id, {String date = '2099-05-01'}) => {
  ...entry(id),
  'id': 'E$id',
  'name': 'Corrida $id com um nome bem comprido para quebrar linhas no banner',
  'date': date,
  'status': 'upcoming',
};

void main() {
  raceArtTests();
  searchTests();
  homeWidthsTests();
  participantsTests();
  bannerTests();
  void big(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('o título longo do banner não cobre os ícones', (tester) async {
    tester.view.physicalSize = const Size(
      390,
      2000,
    ); // largura de iPhone: o título ocupa 3+ linhas
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions/EA') return JsonReply(200, upcoming('A'));
      if (uri.path.startsWith('/me/race-plans/')) {
        return const JsonReply(404, {'code': 'PLAN_NOT_FOUND'});
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'EA'),
      ),
    );
    await tester.pumpAndSettle();
    final icons = tester.getRect(find.byTooltip('Voltar'));
    final title = tester.getRect(find.textContaining('Corrida A com um nome'));
    expect(
      title.top >= icons.bottom,
      isTrue,
      reason: 'título abaixo da linha dos ícones',
    );
    final heart = tester.getRect(find.byKey(const Key('hero-wanted')));
    expect(title.top >= heart.bottom, isTrue);
  });

  testWidgets('quero correr e inscrito: marca, troca e desmarca com o toque', (
    tester,
  ) async {
    big(tester);
    final calls = <String>[];
    Map<String, dynamic>? plan;
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions/EA') return JsonReply(200, upcoming('A'));
      if (uri.path == '/me/race-plans/EA') {
        calls.add('$method ${body ?? ''}');
        if (method == 'PUT') {
          plan = {'editionId': 'EA', 'version': 1, ...?body};
          return JsonReply(200, plan!);
        }
        if (method == 'DELETE') {
          plan = null;
          return const JsonReply(204, {});
        }
        return plan == null
            ? const JsonReply(404, {'code': 'PLAN_NOT_FOUND'})
            : JsonReply(200, plan!);
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'EA'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Criar rascunho'), findsNothing);
    expect(find.byKey(const Key('plan-wanted')), findsOneWidget);
    expect(find.byKey(const Key('plan-registered')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('plan-wanted')));
    await tester.tap(find.byKey(const Key('plan-wanted')));
    await tester.pumpAndSettle();
    expect(plan?['status'], 'wanted');
    expect(find.textContaining('em Desejadas'), findsOneWidget);
    await tester.tap(find.byKey(const Key('plan-registered')));
    await tester.pumpAndSettle();
    expect(plan?['status'], 'registered');
    expect(find.textContaining('em Inscritas'), findsOneWidget);
    await tester.tap(find.byKey(const Key('plan-registered')));
    await tester.pumpAndSettle();
    expect(plan, isNull);
    expect(find.byKey(const Key('plan-note')), findsNothing);
    // O coração do banner faz o mesmo que "Quero correr".
    await tester.tap(find.byKey(const Key('hero-wanted')));
    await tester.pumpAndSettle();
    expect(plan?['status'], 'wanted');
  });

  testWidgets('corrida que já passou só oferece "Já corri"', (tester) async {
    big(tester);
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions/EA') {
        return JsonReply(200, {
          ...upcoming('A', date: '2020-01-01'),
          'status': 'past',
        });
      }
      if (uri.path.startsWith('/me/race-plans/')) {
        return const JsonReply(404, {'code': 'PLAN_NOT_FOUND'});
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'EA'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('10K'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plan-wanted')), findsNothing);
    expect(find.byKey(const Key('plan-registered')), findsNothing);
    expect(find.byKey(const Key('plan-ran')), findsOneWidget);
  });

  testWidgets('agenda separa desejadas e inscritas e permite mover e tirar', (
    tester,
  ) async {
    big(tester);
    final plans = <Map<String, dynamic>>[
      {
        'editionId': 'EA',
        'status': 'wanted',
        'version': 1,
        'edition': upcoming('A'),
      },
      {
        'editionId': 'EB',
        'status': 'registered',
        'version': 1,
        'edition': upcoming('B', date: '2099-03-01'),
      },
    ];
    final calls = <String>[];
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/me/race-plans' && method == 'GET') {
        return JsonReply(200, {'items': plans});
      }
      if (uri.path.startsWith('/me/race-plans/')) {
        final id = uri.pathSegments.last;
        calls.add('$method $id ${body?['status'] ?? ''}');
        final i = plans.indexWhere((p) => p['editionId'] == id);
        if (method == 'DELETE') {
          plans.removeAt(i);
        }
        if (method == 'PUT') {
          plans[i] = {...plans[i], 'status': body!['status']};
        }
        return method == 'DELETE'
            ? const JsonReply(204, {})
            : JsonReply(200, plans[i]);
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: AgendaScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-EA')), findsOneWidget);
    expect(find.byKey(const Key('agenda-EB')), findsNothing);
    await tester.tap(find.byKey(const Key('agenda-tab-registered')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-EB')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agenda-tab-wanted')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('agenda-menu-EA')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marcar como inscrito'));
    await tester.pumpAndSettle();
    expect(calls.last, 'PUT EA registered');
    expect(find.byKey(const Key('agenda-empty-wanted')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agenda-tab-registered')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-EA')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agenda-menu-EB')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tirar da agenda'));
    await tester.pumpAndSettle();
    expect(calls.last, 'DELETE EB ');
    expect(find.byKey(const Key('agenda-EB')), findsNothing);
  });

  Future<void> openCalendar(
    WidgetTester tester,
    List<Map<String, dynamic>> plans,
  ) async {
    big(tester);
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/me/race-plans' && method == 'GET') {
        return JsonReply(200, {'items': plans});
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: AgendaScreen(gateway: gateway)));
    await tester.pumpAndSettle();
  }

  List<Map<String, dynamic>> calendarPlans() => [
    {
      'editionId': 'EA',
      'status': 'wanted',
      'version': 1,
      'edition': upcoming('A', date: '2099-01-10'),
    },
    {
      'editionId': 'EC',
      'status': 'wanted',
      'version': 1,
      'edition': upcoming('C', date: '2099-01-20'),
    },
    {
      'editionId': 'ED',
      'status': 'wanted',
      'version': 1,
      'edition': upcoming('D', date: '2099-03-05'),
    },
    {
      'editionId': 'EB',
      'status': 'registered',
      'version': 1,
      'edition': upcoming('B', date: '2099-06-15'),
    },
  ];

  test('monthCells: grade que começa no domingo, com células em branco', () {
    // 1/11/2026 é domingo: sem células em branco antes do dia 1.
    final nov = monthCells(DateTime(2026, 11));
    expect(nov.where((c) => c == null).length, 0);
    expect(nov.length, 30);
    // 1/12/2026 é terça: duas células em branco.
    final dec = monthCells(DateTime(2026, 12));
    expect(dec.where((c) => c == null).length, 2);
    expect(dec.whereType<DateTime>().length, 31);
    // fevereiro de 2024 (bissexto) começa numa quinta: 4 em branco e 29 dias.
    final feb = monthCells(DateTime(2024, 2));
    expect(feb.where((c) => c == null).length, 4);
    expect(feb.whereType<DateTime>().length, 29);
  });

  testWidgets('a agenda é um calendário do mês da próxima corrida, com os dias '
      'das corridas marcados', (tester) async {
    await openCalendar(tester, calendarPlans());
    expect(find.byKey(const Key('agenda-calendar-wanted')), findsOneWidget);
    expect(find.text('janeiro de 2099'), findsOneWidget);
    expect(find.text('D'), findsWidgets); // cabeçalho dos dias da semana
    // os dias 10 e 20 existem e respondem ao toque; um dia sem corrida não
    expect(
      find.byKey(const Key('agenda-day-wanted-2099-01-10')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agenda-day-wanted-2099-01-20')),
      findsOneWidget,
    );
    final semCorrida = tester.widget<InkWell>(
      find.byKey(const Key('agenda-day-wanted-2099-01-11')),
    );
    expect(semCorrida.onTap, isNull);
    // a lista abaixo mostra todas as corridas da aba, de qualquer mês
    for (final id in ['EA', 'EC', 'ED']) {
      expect(find.byKey(Key('agenda-$id')), findsOneWidget);
    }
    expect(find.byKey(const Key('agenda-EB')), findsNothing); // é de Inscritas
  });

  testWidgets('tocar num dia mostra só as corridas dele e "Ver todas" volta', (
    tester,
  ) async {
    await openCalendar(tester, calendarPlans());
    await tester.tap(find.byKey(const Key('agenda-day-wanted-2099-01-10')));
    await tester.pumpAndSettle();
    expect(find.text('Corridas em 10/01/2099'), findsOneWidget);
    expect(find.byKey(const Key('agenda-EA')), findsOneWidget);
    expect(find.byKey(const Key('agenda-EC')), findsNothing);
    expect(find.byKey(const Key('agenda-ED')), findsNothing);
    // tocar no mesmo dia de novo desmarca
    await tester.tap(find.byKey(const Key('agenda-day-wanted-2099-01-10')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-EC')), findsOneWidget);
    // outro dia, e "Ver todas"
    await tester.tap(find.byKey(const Key('agenda-day-wanted-2099-01-20')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-EA')), findsNothing);
    expect(find.byKey(const Key('agenda-EC')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agenda-clear-day-wanted')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-EA')), findsOneWidget);
    expect(find.byKey(const Key('agenda-ED')), findsOneWidget);
  });

  testWidgets('as setas trocam o mês e limpam o dia escolhido', (tester) async {
    await openCalendar(tester, calendarPlans());
    await tester.tap(find.byKey(const Key('agenda-day-wanted-2099-01-10')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('agenda-next-wanted')));
    await tester.pumpAndSettle();
    expect(find.text('fevereiro de 2099'), findsOneWidget);
    expect(find.text('Corridas em 10/01/2099'), findsNothing); // dia limpo
    await tester.tap(find.byKey(const Key('agenda-next-wanted')));
    await tester.pumpAndSettle();
    expect(find.text('março de 2099'), findsOneWidget);
    expect(
      find.byKey(const Key('agenda-day-wanted-2099-03-05')),
      findsOneWidget,
    );
    // virada de ano para trás: de janeiro para dezembro do ano anterior
    await tester.tap(find.byKey(const Key('agenda-prev-wanted')));
    await tester.tap(find.byKey(const Key('agenda-prev-wanted')));
    await tester.tap(find.byKey(const Key('agenda-prev-wanted')));
    await tester.pumpAndSettle();
    expect(find.text('dezembro de 2098'), findsOneWidget);
  });

  testWidgets('cada aba tem o seu calendário, no mês da sua próxima corrida', (
    tester,
  ) async {
    await openCalendar(tester, calendarPlans());
    expect(find.text('janeiro de 2099'), findsOneWidget);
    await tester.tap(find.byKey(const Key('agenda-tab-registered')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agenda-calendar-registered')), findsOneWidget);
    expect(find.text('junho de 2099'), findsOneWidget);
    expect(
      find.byKey(const Key('agenda-day-registered-2099-06-15')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agenda-EB')), findsOneWidget);
  });

  testWidgets('sem corridas a agenda mostra o calendário do mês atual e o '
      'aviso', (tester) async {
    await openCalendar(tester, []);
    expect(find.byKey(const Key('agenda-calendar-wanted')), findsOneWidget);
    expect(find.byKey(const Key('agenda-empty-wanted')), findsOneWidget);
    final hoje = DateTime.now();
    const meses = [
      'janeiro',
      'fevereiro',
      'março',
      'abril',
      'maio',
      'junho',
      'julho',
      'agosto',
      'setembro',
      'outubro',
      'novembro',
      'dezembro',
    ];
    expect(
      find.text('${meses[hoje.month - 1]} de ${hoje.year}'),
      findsOneWidget,
    );
  });

  testWidgets('ao digitar o nome, sugere as corridas para escolher uma', (
    tester,
  ) async {
    big(tester);
    final calls = <Uri>[];
    final gateway = await signed((uri, method, headers, body) async {
      calls.add(uri);
      if (uri.path == '/editions' && uri.queryParameters['q'] != null) {
        return JsonReply(200, {
          'items': [
            {...entry('A'), 'id': 'EA', 'name': 'Circuito das Estações Verão'},
            {
              ...entry('B'),
              'id': 'EB',
              'name': 'Circuito das Estações Primavera',
            },
          ],
        });
      }
      if (uri.path == '/editions/EB') {
        return JsonReply(200, {
          ...entry('B'),
          'id': 'EB',
          'name': 'Circuito das Estações Primavera',
        });
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('catalog-phrase')), 'circuito');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-suggestions')), findsOneWidget);
    expect(find.text('Encontramos 2 corridas. Escolha uma:'), findsOneWidget);
    expect(calls.any((u) => u.queryParameters['q'] == 'circuito'), isTrue);
    await tester.tap(find.byKey(const Key('suggestion-EB')));
    await tester.pumpAndSettle();
    expect(find.byType(EditionScreen), findsOneWidget);
    expect(find.text('Circuito das Estações Primavera'), findsOneWidget);
  });

  testWidgets(
    'texto curto não pede sugestões e a falha delas não mostra erro',
    (tester) async {
      big(tester);
      final calls = <Uri>[];
      final gateway = await signed((uri, method, headers, body) async {
        calls.add(uri);
        if (uri.queryParameters['q'] != null) {
          return const JsonReply(503, {'code': 'X'});
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('catalog-phrase')), 'c');
      await tester.pump(const Duration(milliseconds: 600));
      expect(calls.where((u) => u.queryParameters['q'] != null), isEmpty);
      await tester.enterText(find.byKey(const Key('catalog-phrase')), 'cir');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('catalog-suggestions')), findsNothing);
      expect(find.byKey(const Key('catalog-error')), findsNothing);
    },
  );

  testWidgets(
    'a home mostra a agenda ao lado de Minha Cidade e abre a agenda',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844); // largura de iPhone
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/me') {
          return const JsonReply(200, {
            'id': 'me',
            'displayName': 'Eu',
            'username': 'eu',
            'version': 1,
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      final icon = find.byKey(const Key('home-agenda-chip'));
      // Todos os cinco atalhos ficam inteiros dentro da tela, sem rolar.
      for (final label in [
        'Todos',
        'Amigos',
        'Seguindo',
        'Minha Cidade',
        'Agenda',
      ]) {
        final r = tester.getRect(find.text(label));
        expect(
          r.left >= 0 && r.right <= 390,
          isTrue,
          reason: '$label dentro da tela',
        );
      }
      // Na fonte larga dos testes o último círculo fica além da borda; rola o carrossel até ele.
      await tester.dragUntilVisible(
        icon,
        find.text('Todos'),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();
      expect(icon, findsOneWidget);
      expect(
        find.byKey(const Key('home-agenda')),
        findsNothing,
      ); // saiu da barra do topo
      final cidade = tester.getRect(find.text('Minha Cidade'));
      expect(
        tester.getRect(icon).left > cidade.right - 1,
        isTrue,
        reason: 'depois de Minha Cidade',
      );
      final rect = tester.getRect(icon);
      expect(
        rect.left >= 0 && rect.right <= 390,
        isTrue,
        reason: 'ícone visível na largura do iPhone',
      );
      await tester.tap(icon);
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(find.text('Minha agenda'), findsOneWidget);
    },
  );
}

void participantsTests() {
  Future<void> openTab(WidgetTester tester, Map<String, dynamic> page) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions/EA') return JsonReply(200, upcoming('A'));
      if (uri.path == '/editions/EA/participants') return JsonReply(200, page);
      if (uri.path.startsWith('/me/race-plans/')) {
        return const JsonReply(404, {'code': 'PLAN_NOT_FOUND'});
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'EA'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Participantes'));
    await tester.pumpAndSettle();
  }

  testWidgets('aba Participantes lista nome, distância, tempo e colocação', (
    tester,
  ) async {
    await openTab(tester, {
      'total': 3,
      'items': [
        {
          'participationId': 'p1',
          'author': {
            'id': 'u1',
            'displayName': 'Ana Souza',
            'username': 'ana',
            'version': 1,
          },
          'distanceId': '10k',
          'timeSeconds': 3125,
          'placement': 12,
        },
        {
          'participationId': 'p2',
          'author': {
            'id': 'u2',
            'displayName': 'Bruno Lima',
            'username': 'bruno',
            'version': 1,
          },
          'distanceId': '5k',
        },
      ],
    });
    expect(find.text('3 corredores concluíram esta prova'), findsOneWidget);
    expect(find.text('Ana Souza'), findsOneWidget);
    expect(find.textContaining('10K · 52:05 · 12º lugar'), findsOneWidget);
    expect(find.textContaining('@bruno'), findsOneWidget);
    expect(find.byKey(const Key('participants-hidden')), findsOneWidget);
    expect(find.textContaining('1 participante não aparece'), findsOneWidget);
  });

  testWidgets(
    'sem ninguém, convida a registrar; falha do servidor diz o que houve',
    (tester) async {
      await openTab(tester, {'total': 0, 'items': []});
      expect(
        find.textContaining('Ninguém concluiu esta prova'),
        findsOneWidget,
      );
    },
  );
}

void bannerTests() {
  Future<List<String>> openEdition(
    WidgetTester tester,
    Map<String, dynamic> edition,
    JsonReply Function() banner,
  ) async {
    tester.view.physicalSize = const Size(390, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final paths = <String>[];
    final gateway = await signed((uri, method, headers, body) async {
      paths.add(uri.path);
      if (uri.path == '/editions/EA') return JsonReply(200, edition);
      if (uri.path == '/editions/EA/banner') return banner();
      if (uri.path.startsWith('/me/race-plans/')) {
        return const JsonReply(404, {'code': 'PLAN_NOT_FOUND'});
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'EA'),
      ),
    );
    await tester.pumpAndSettle();
    return paths;
  }

  testWidgets('banner aprovado aparece com o crédito', (tester) async {
    await openEdition(
      tester,
      {
        ...upcoming('A'),
        'imageReference': 'banner_x',
        'imageCredit': 'Divulgação: Org',
      },
      () => const JsonReply(200, {
        'url': 'https://img.exemplo.invalid/banner.png',
        'contentType': 'image/png',
        'expiresAt': '2099-01-01T00:00:00Z',
        'credit': 'Divulgação: Org',
      }),
    );
    expect(find.byKey(const Key('hero-image')), findsOneWidget);
    expect(find.text('Foto: Divulgação: Org'), findsOneWidget);
    expect(find.textContaining('Corrida A com um nome'), findsOneWidget);
  });

  testWidgets('sem banner aprovado não pede imagem nem mostra crédito', (
    tester,
  ) async {
    final paths = await openEdition(
      tester,
      upcoming('A'),
      () => const JsonReply(404, {'code': 'IMAGE_NOT_AVAILABLE'}),
    );
    expect(paths.contains('/editions/EA/banner'), isFalse);
    expect(find.byKey(const Key('hero-image')), findsNothing);
    expect(find.byKey(const Key('hero-credit')), findsNothing);
  });

  testWidgets('falha ao buscar o banner mantém o degradê e a tela', (
    tester,
  ) async {
    await openEdition(tester, {
      ...upcoming('A'),
      'imageReference': 'banner_x',
      'imageCredit': 'Divulgação: Org',
    }, () => const JsonReply(503, {'code': 'UNAVAILABLE'}));
    expect(find.byKey(const Key('hero-image')), findsNothing);
    expect(find.byKey(const Key('hero-credit')), findsNothing);
    expect(find.textContaining('Corrida A com um nome'), findsOneWidget);
  });
}

void homeWidthsTests() {
  for (final width in [320.0, 360.0, 411.0, 430.0]) {
    testWidgets('os cinco atalhos da home cabem em ${width.toInt()} pt', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/me') {
          return const JsonReply(200, {
            'id': 'me',
            'displayName': 'Eu',
            'username': 'eu',
            'version': 1,
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      for (final label in [
        'Todos',
        'Amigos',
        'Seguindo',
        'Minha Cidade',
        'Agenda',
      ]) {
        final r = tester.getRect(find.text(label));
        expect(
          r.left >= 0 && r.right <= width,
          isTrue,
          reason: '$label em $width',
        );
      }
    });
  }
}

void searchTests() {
  test('ano vira o intervalo do ano todo e anos inválidos são recusados', () {
    expect(yearRange('2026'), (from: '2026-01-01', to: '2026-12-31'));
    expect(yearRange(' 2024 '), (from: '2024-01-01', to: '2024-12-31'));
    for (final bad in ['', 'abc', '26', '1850', '2026-11', '2101']) {
      expect(yearRange(bad), isNull, reason: bad);
    }
    expect(filterYears(DateTime(2026, 11, 10)), [2027, 2026, 2025, 2024]);
  });

  Future<List<Map<String, String>>> openForm(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <Map<String, String>>[];
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions') calls.add(uri.queryParameters);
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('catalog-search-toggle')));
    await tester.pumpAndSettle();
    return calls;
  }

  Future<void> pick(WidgetTester tester, String field, String option) async {
    final box = find.byKey(ValueKey('$field-0'));
    await tester.ensureVisible(box);
    await tester.tap(box);
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> pickLocation(WidgetTester tester) async {
    // Mesmo seletor do editar perfil; aceitar o padrão escolhe o primeiro da lista (Acre / Acrelândia).
    final field = find.byKey(const Key('filter-location'));
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('location-done')));
    await tester.pumpAndSettle();
  }

  testWidgets('só o nome é obrigatório; estado e cidade e ano são seletores', (
    tester,
  ) async {
    final calls = await openForm(tester);
    final before = calls.length;
    await tester.ensureVisible(find.text('Buscar'));
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    expect(
      find.text('Informe o nome da corrida ou escolha outro filtro.'),
      findsOneWidget,
    );
    expect(calls.length, before, reason: 'sem nome nada é enviado');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nome da corrida'),
      'meia',
    );
    await pickLocation(tester);
    await pick(tester, 'filter-year', '2026');
    await tester.ensureVisible(find.text('Buscar'));
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    expect(calls.last['namePrefix'], 'meia');
    expect(calls.last['state'], 'AC');
    expect(calls.last['city'], 'Acrelândia');
    expect(calls.last['dateFrom'], '2026-01-01');
    expect(calls.last['dateTo'], '2026-12-31');
    expect(
      calls.last.containsKey('distanceKm'),
      isFalse,
    ); // distância e o resto são opcionais
  });

  testWidgets('com outro filtro o nome deixa de ser obrigatório', (
    tester,
  ) async {
    final calls = await openForm(tester);
    await pick(tester, 'filter-year', '2026');
    await tester.ensureVisible(find.text('Buscar'));
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    expect(
      find.text('Informe o nome da corrida ou escolha outro filtro.'),
      findsNothing,
    );
    expect(calls.last.containsKey('namePrefix'), isFalse);
    expect(calls.last['dateFrom'], '2026-01-01');
    expect(calls.last['dateTo'], '2026-12-31');
  });

  testWidgets('atalhos de km preenchem a distância e a busca a envia', (
    tester,
  ) async {
    final calls = await openForm(tester);
    final chip = find.byKey(const Key('km-chip-10'));
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '10'), findsOneWidget);
    await tester.ensureVisible(find.text('Buscar'));
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    expect(calls.last['distanceKm'], '10');
    expect(calls.last.containsKey('namePrefix'), isFalse);
    // tocar de novo no atalho selecionado limpa a distância
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '10'), findsNothing);
  });

  testWidgets('limpar a busca zera UF e ano nos seletores', (tester) async {
    final calls = await openForm(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nome da corrida'),
      'meia',
    );
    await pickLocation(tester);
    await pick(tester, 'filter-year', '2025');
    await tester.ensureVisible(find.text('Buscar'));
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    expect(calls.last['state'], 'AC');
    await tester.ensureVisible(find.text('Limpar busca'));
    await tester.tap(find.text('Limpar busca'));
    await tester.pumpAndSettle();
    expect(calls.last.containsKey('state'), isFalse);
    expect(calls.last.containsKey('dateFrom'), isFalse);
    expect(find.text('Todos os estados e cidades'), findsOneWidget);
    expect(find.text('Qualquer ano'), findsOneWidget);
  });

  testWidgets('pedir cadastro e minhas solicitações ficam sempre visíveis', (
    tester,
  ) async {
    await openForm(tester);
    await tester.tap(
      find.byKey(const Key('catalog-search-toggle')),
    ); // fecha a lupa
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-request-new')), findsOneWidget);
    expect(find.byKey(const Key('catalog-request-mine')), findsOneWidget);
    expect(find.text('Minhas solicitações'), findsOneWidget);
  });

  testWidgets(
    'a lista mostra a imagem aprovada e só pede link de quem tem imagem',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      EditionCover.cache.clear();
      final banners = <String>[];
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions') {
          return JsonReply(200, {
            'items': [
              {...entry('A'), 'id': 'EA', 'imageReference': 'banner_x'},
              {...entry('B'), 'id': 'EB'},
            ],
          });
        }
        if (uri.path.endsWith('/banner')) {
          banners.add(uri.path);
          return const JsonReply(200, {
            'url': 'https://img.exemplo.invalid/a.png',
            'contentType': 'image/png',
            'expiresAt': '2099-01-01T00:00:00Z',
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(banners, ['/editions/EA/banner']);
      expect(find.byKey(const Key('edition-cover-image')), findsOneWidget);
      // A outra corrida segue com o ícone, sem imagem.
      expect(find.byType(EditionCover), findsNWidgets(2));
      // Sem imagem, a distância da arte fica no canto superior esquerdo do cartão.
      expect(
        tester.widget<RaceArt>(find.byType(RaceArt).first).labelAtLeft,
        isTrue,
      );
    },
  );
}

void raceArtTests() {
  testWidgets(
    'corrida sem imagem tem arte própria no banner e na lista, sempre a mesma',
    (tester) async {
      tester.view.physicalSize = const Size(390, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions/EA') {
          return JsonReply(200, {
            ...upcoming('A'),
            'distances': [
              {'id': '5k', 'kilometers': 5},
              {'id': '21k', 'kilometers': 21.097},
            ],
          });
        }
        if (uri.path.startsWith('/me/race-plans/')) {
          return const JsonReply(404, {'code': 'PLAN_NOT_FOUND'});
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: EditionScreen(gateway: gateway, editionId: 'EA'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('race-art')), findsOneWidget);
      expect(
        find.text('21K'),
        findsOneWidget,
      ); // a maior distância identifica a prova
      expect(find.byKey(const Key('hero-image')), findsNothing);
    },
  );

  test('a cor da arte é estável por corrida e varia entre corridas', () {
    List<Color> of(String id) =>
        RaceArt(edition: {'id': id, 'distances': const []}).colors;
    expect(of('csv-sp-corrida-x'), of('csv-sp-corrida-x'));
    final distinct = {
      for (var i = 0; i < 40; i++) of('corrida-$i').first.toARGB32(),
    };
    expect(distinct.length > 1, isTrue);
  });
}
