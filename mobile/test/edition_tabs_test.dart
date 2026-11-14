import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/friends.dart';
import 'package:runpass/identity_gateway.dart';

const edition = {
  'id': 'E1',
  'name': '[FICTICIA] Circuito das Estações',
  'date': '2024-09-22',
  'city': 'São Paulo',
  'state': 'SP',
  'status': 'past',
  'version': 1,
  'distances': [
    {'id': '5k', 'kilometers': 5},
    {'id': '10k', 'kilometers': 10},
  ],
};

Map<String, dynamic> person(String id) => {
  'id': id,
  'displayName': 'Pessoa $id',
  'username': 'user_$id',
  'version': 1,
  'isPrivate': false,
  'followState': 'none',
  'friendState': 'none',
};

const myRatings = {
  'organization': 5,
  'course': 4,
  'kit': 3,
  'medal': 5,
  'hydration': 4,
  'facilities': 2,
  'safety': 4,
  'valueForMoney': 3,
};

Future<IdentityGateway> gatewayWith({
  Map<String, dynamic>? reviews,
  Map<String, dynamic>? photos,
  Map<String, dynamic>? participants,
  Map<String, dynamic>? registrants,
  bool completedByMe = false,
}) async {
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
      if (uri.path == '/editions/E1') return const JsonReply(200, edition);
      if (uri.path == '/editions/E1/reviews') {
        return JsonReply(
          200,
          reviews ??
              {
                'items': [],
                'summary': {'reviewCount': 0},
              },
        );
      }
      if (uri.path == '/editions/E1/participants' && participants != null) {
        return JsonReply(200, participants);
      }
      if (uri.path == '/editions/E1/registrants' && registrants != null) {
        return JsonReply(200, registrants);
      }
      if (uri.path == '/editions/E1/photos') {
        if (photos == null) return const JsonReply(503, {'code': 'X'});
        return JsonReply(200, photos);
      }
      if (completedByMe && uri.path == '/me/participations') {
        return const JsonReply(200, {
          'items': [
            {
              'id': 'mine-1',
              'editionId': 'E1',
              'distanceId': '10k',
              'state': 'completed',
              'medalImageReference': 'img_mine',
            },
          ],
        });
      }
      if (completedByMe && uri.path == '/participations/mine-1/review') {
        return const JsonReply(200, {
          'ratings': myRatings,
          'comment': 'Gostei muito',
        });
      }
      if (uri.path == '/me/race-plans/E1') {
        return const JsonReply(404, {'code': 'PLAN_NOT_FOUND'});
      }
      return const JsonReply(200, {'items': [], 'total': 0});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return gateway;
}

Future<void> open(
  WidgetTester tester,
  IdentityGateway gateway,
  String tab,
) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: EditionScreen(gateway: gateway, editionId: 'E1'),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(tab));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Avaliações: média, quantidade e as '
      'barras dos itens', (tester) async {
    final gateway = await gatewayWith(
      reviews: {
        'items': [],
        'summary': {
          'reviewCount': 1284,
          'average': 4.7,
          'recommendPercent': 97,
          'byCriterion': {
            'organization': 4.8,
            'course': 4.6,
            'kit': 4.5,
            'medal': 4.9,
            'hydration': 4.6,
            'facilities': 4.0,
            'safety': 4.2,
            'valueForMoney': 4.3,
          },
        },
      },
    );
    await open(tester, gateway, 'Avaliações');
    // O nome da corrida já está no banner: a aba não o repete, nem data e local.
    expect(find.text('22 de setembro de 2024'), findsNothing);
    expect(find.text('São Paulo - SP'), findsNothing);
    expect(find.text('4,7'), findsOneWidget);
    expect(find.text('1.284 avaliações'), findsOneWidget);
    expect(find.text('97%'), findsOneWidget);
    expect(find.text('recomendariam\nesta prova'), findsOneWidget);
    for (final label in [
      'Organização',
      'Percurso',
      'Kit',
      'Medalha',
      'Hidratação',
      'Estrutura',
      'Segurança',
      'Custo-benefício',
    ]) {
      expect(find.byKey(Key('bar-$label')), findsOneWidget, reason: label);
    }
    expect(find.text('4,8'), findsOneWidget);
    expect(find.text('4,9'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('bar-Organização')),
    );
    expect(bar.value, closeTo(4.8 / 5, 0.001));
  });

  testWidgets('Avaliações sem notas ainda mostra o cartão da média, vazio', (
    tester,
  ) async {
    final gateway = await gatewayWith();
    await open(tester, gateway, 'Avaliações');
    expect(find.byKey(const Key('reviews-none')), findsOneWidget);
    expect(find.text('-'), findsWidgets);
  });

  testWidgets('Fotos: as fotos postadas aparecem em grade de 3 por linha', (
    tester,
  ) async {
    final gateway = await gatewayWith(
      photos: {
        'items': [
          for (final id in ['a', 'b', 'c', 'd'])
            {
              'participationId': 'p-$id',
              'author': person(id),
              'distanceId': '10k',
              'completedAt': '2024-09-22T10:00:00Z',
            },
        ],
        'total': 4,
      },
    );
    await open(tester, gateway, 'Fotos');
    expect(find.text('4 fotos desta prova'), findsOneWidget);
    Offset at(String id) => tester.getTopLeft(find.byKey(Key('photo-p-$id')));
    expect(at('a').dy, at('b').dy);
    expect(at('b').dy, at('c').dy);
    expect(at('d').dy, greaterThan(at('a').dy));
    expect(at('a').dx, lessThan(at('b').dx));
    final grid = tester.getSize(find.byKey(const Key('photos-grid')));
    expect(
      tester.getSize(find.byKey(const Key('photo-p-a'))).width,
      closeTo((grid.width - 8) / 3, 1),
    );
    await tester.tap(find.byKey(const Key('photo-p-a')));
    await tester.pumpAndSettle();
    expect(find.text('@user_a'), findsOneWidget);
  });

  testWidgets('Fotos: dá para escolher o número de colunas da grade', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final gateway = await gatewayWith(
      photos: {
        'items': [
          for (final id in ['a', 'b', 'c', 'd'])
            {
              'participationId': 'p-$id',
              'author': person(id),
              'distanceId': '10k',
              'completedAt': '2024-09-22T10:00:00Z',
            },
        ],
        'total': 4,
      },
    );
    await open(tester, gateway, 'Fotos');
    double top(String id) =>
        tester.getTopLeft(find.byKey(Key('photo-p-$id'))).dy;
    expect(top('a'), top('c'));
    await tester.tap(find.byKey(const Key('grid-columns-photos')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('grid-columns-4')));
    await tester.pumpAndSettle();
    expect(top('a'), top('d')); // 4 por linha: as quatro lado a lado
    await tester.tap(find.byKey(const Key('grid-columns-photos')));
    await tester.pumpAndSettle();
    // A grade começa em 2 colunas: 1 coluna seria igual à lista.
    expect(find.byKey(const Key('grid-columns-1')), findsNothing);
    await tester.tap(find.byKey(const Key('grid-columns-2')));
    await tester.pumpAndSettle();
    expect(top('a'), top('b'));
    expect(top('c'), greaterThan(top('a'))); // 2 por linha
  });

  testWidgets('a avaliação geral fica acima da minha, com os mesmos itens, e '
      'os detalhes de cada uma recolhem e expandem', (tester) async {
    final gateway = await gatewayWith(
      completedByMe: true,
      reviews: {
        'items': [],
        'summary': {
          'reviewCount': 12,
          'average': 4.2,
          'recommendPercent': 80,
          'byCriterion': {for (final k in myRatings.keys) k: 4.0},
        },
      },
    );
    await open(tester, gateway, 'Avaliações');
    // geral (média + quantidade) acima da minha
    final score = tester.getTopLeft(find.byKey(const Key('score-card'))).dy;
    final mine = tester.getTopLeft(find.byKey(const Key('my-review'))).dy;
    expect(score, lessThan(mine));
    expect(find.text('12 avaliações'), findsOneWidget);
    // mesmos oito itens nas duas
    const labels = [
      'Organização',
      'Percurso',
      'Kit',
      'Medalha',
      'Hidratação',
      'Estrutura',
      'Segurança',
      'Custo-benefício',
    ];
    for (final label in labels) {
      expect(find.byKey(Key('bar-$label')), findsOneWidget, reason: label);
      expect(
        find.descendant(
          of: find.byKey(const Key('my-review')),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: 'minha avaliação sem $label',
      );
    }
    // a média geral e a quantidade de avaliações ficam junto dos itens
    expect(
      find.descendant(
        of: find.byKey(const Key('summary-overall')),
        matching: find.text('Média geral'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('summary-overall')),
        matching: find.textContaining('avaliaç'),
      ),
      findsOneWidget,
    );
    // recolher a geral
    await tester.tap(find.byKey(const Key('summary-details-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('summary-details')), findsNothing);
    expect(find.byKey(const Key('score-card')), findsOneWidget); // resumo segue
    await tester.tap(find.byKey(const Key('summary-details-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('summary-details')), findsOneWidget);
    // recolher a minha: itens e comentário somem, o título fica
    await tester.tap(find.byKey(const Key('my-details-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('“Gostei muito”'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('my-review')),
        matching: find.text('Organização'),
      ),
      findsNothing,
    );
    expect(find.text('Minha avaliação'), findsOneWidget);
    await tester.tap(find.byKey(const Key('my-details-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('“Gostei muito”'), findsOneWidget);
  });

  testWidgets('Fotos: a minha foto aparece mesmo se a lista pública falhar', (
    tester,
  ) async {
    final gateway = await gatewayWith(completedByMe: true); // /photos dá 503
    await open(tester, gateway, 'Fotos');
    expect(find.byKey(const Key('photo-mine-1')), findsOneWidget);
    expect(find.byKey(const Key('photos-partial')), findsOneWidget);
    expect(find.text('1 foto desta prova'), findsOneWidget);
  });

  testWidgets('Fotos: a minha vem primeiro e não repete se já está na lista', (
    tester,
  ) async {
    final gateway = await gatewayWith(
      completedByMe: true,
      photos: {
        'items': [
          {
            'participationId': 'p-a',
            'author': person('a'),
            'distanceId': '10k',
            'completedAt': '2024-09-22T10:00:00Z',
          },
          {
            'participationId': 'mine-1',
            'author': person('eu'),
            'distanceId': '10k',
            'completedAt': '2024-09-22T09:00:00Z',
          },
        ],
        'total': 2,
      },
    );
    await open(tester, gateway, 'Fotos');
    expect(
      find.byKey(const Key('photo-mine-1')),
      findsOneWidget,
    ); // sem duplicar
    expect(find.byKey(const Key('photo-p-a')), findsOneWidget);
    expect(find.text('2 fotos desta prova'), findsOneWidget);

    final solo = await gatewayWith(
      completedByMe: true,
      photos: {'items': [], 'total': 0},
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await open(tester, solo, 'Fotos');
    expect(find.byKey(const Key('photo-mine-1')), findsOneWidget);
    expect(find.text('1 foto desta prova'), findsOneWidget);
  });

  testWidgets('Participantes: inscritos e quem concluiu, cada um com a foto do '
      'perfil', (tester) async {
    final gateway = await gatewayWith(
      registrants: {
        'items': [
          {'author': person('a'), 'distanceId': '10k', 'registeredAt': 'x'},
          {'author': person('b'), 'registeredAt': 'y'},
        ],
        'total': 3,
      },
      participants: {
        'items': [
          {
            'participationId': 'p-c',
            'author': person('c'),
            'distanceId': '10k',
            'completedAt': '2024-09-22T10:00:00Z',
          },
        ],
        'total': 1,
      },
    );
    await open(tester, gateway, 'Participantes');
    expect(find.text('3 inscritos nesta prova'), findsOneWidget);
    expect(find.text('1 corredor concluiu esta prova'), findsOneWidget);
    expect(find.byKey(const Key('registrant-a')), findsOneWidget);
    expect(find.byKey(const Key('registrant-b')), findsOneWidget);
    expect(find.byKey(const Key('participant-p-c')), findsOneWidget);
    expect(
      find.text('1 inscrito não aparece porque o perfil é privado.'),
      findsOneWidget,
    );
    // A foto do perfil (ProfileAvatar) em cada linha, não mais a inicial do nome.
    for (final key in ['registrant-a', 'registrant-b', 'participant-p-c']) {
      expect(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(ProfileAvatar),
        ),
        findsOneWidget,
        reason: key,
      );
    }
    // Inscritos primeiro, depois quem concluiu.
    expect(
      tester.getTopLeft(find.byKey(const Key('registrant-a'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('participant-p-c'))).dy),
    );
  });

  testWidgets(
    'Participantes: sem ninguém inscrito nem concluído mostra o aviso',
    (tester) async {
      final gateway = await gatewayWith();
      await open(tester, gateway, 'Participantes');
      expect(
        find.textContaining('Ninguém concluiu nem se inscreveu'),
        findsOneWidget,
      );
    },
  );

  final onePixelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  Future<(IdentityGateway, List<String>, List<Map<String, dynamic>?>)>
  suggestionGateway({int status = 201, String code = 'X'}) async {
    final calls = <String>[];
    final bodies = <Map<String, dynamic>?>[];
    final gateway = IdentityGateway(
      cognito: Uri.parse('https://cognito.example'),
      api: Uri.parse('https://api.example'),
      clientId: 'synthetic',
      byteTransport: (uri, method, headers, bytes) async => 200,
      transport: (uri, method, headers, body) async {
        if (uri.host == 'cognito.example') {
          return const JsonReply(200, {
            'AuthenticationResult': {'AccessToken': 'synthetic'},
          });
        }
        calls.add('$method ${uri.path}');
        if (uri.path == '/editions/E1') return const JsonReply(200, edition);
        if (uri.path == '/uploads') {
          return const JsonReply(201, {
            'uploadId': 'up1',
            'uploadUrl': 'https://signed.example/up1',
            'uploadMethod': 'PUT',
            'uploadHeaders': {'Content-Type': 'image/png'},
          });
        }
        if (uri.path == '/uploads/up1/finalize') {
          return JsonReply(200, {
            'uploadId': 'up1',
            'state': 'valid',
            'imageReference': 'img_${'a' * 64}',
          });
        }
        if (uri.path == '/editions/E1/banner-suggestions') {
          bodies.add(body);
          return status == 201
              ? const JsonReply(201, {'id': 'r1', 'status': 'linked'})
              : JsonReply(status, {'code': code});
        }
        return const JsonReply(200, {'items': [], 'total': 0});
      },
    );
    await gateway.signIn('synthetic@example.test', 'synthetic');
    return (gateway, calls, bodies);
  }

  Future<void> tapSuggest(WidgetTester tester, IdentityGateway gateway) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(
          gateway: gateway,
          editionId: 'E1',
          bannerSelector: (context) async => onePixelPng,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('suggest-banner'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Sugerir banner: envia a imagem e a sugestão só leva a referência',
    (tester) async {
      final (gateway, calls, bodies) = await suggestionGateway();
      await tapSuggest(tester, gateway);
      expect(calls.where((c) => c.startsWith('POST')), [
        'POST /uploads',
        'POST /uploads/up1/finalize',
        'POST /editions/E1/banner-suggestions',
      ]);
      expect(bodies.single, {'imageReference': 'img_${'a' * 64}'});
      expect(
        find.textContaining('A equipe confere a autorização'),
        findsWidgets,
      );
      expect(find.text('Sugerir banner desta corrida'), findsOneWidget);
    },
  );

  testWidgets('Sugerir banner: avisa quando já há uma sugestão aguardando', (
    tester,
  ) async {
    final (gateway, _, _) = await suggestionGateway(
      status: 409,
      code: 'BANNER_SUGGESTION_EXISTS',
    );
    await tapSuggest(tester, gateway);
    expect(find.textContaining('aguarda a decisão da equipe'), findsOneWidget);
  });

  testWidgets('Fotos: sem fotos mostra o aviso', (tester) async {
    final empty = await gatewayWith(photos: {'items': [], 'total': 0});
    await open(tester, empty, 'Fotos');
    expect(find.text('As fotos desta prova aparecerão aqui.'), findsOneWidget);
  });

  testWidgets('Fotos: falha ao carregar avisa', (tester) async {
    final failing = await gatewayWith();
    await open(tester, failing, 'Fotos');
    expect(
      find.text('Não foi possível carregar as fotos agora.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'Sobre mostra a nota média e a quantidade; tocar leva a Avaliações',
    (tester) async {
      final gateway = await gatewayWith(
        reviews: {
          'items': [],
          'summary': {'reviewCount': 1284, 'average': 4.7},
        },
      );
      await open(tester, gateway, 'Sobre');
      expect(find.byKey(const Key('about-rating')), findsOneWidget);
      expect(find.text('4,7'), findsOneWidget);
      expect(find.text('1.284 avaliações'), findsOneWidget);
      expect(find.byKey(const Key('summary-details-toggle')), findsNothing);
      await tester.tap(find.byKey(const Key('about-rating')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('summary-details-toggle')), findsOneWidget);
    },
  );

  testWidgets('trocar de aba a partir da corrida não deixa seta de voltar', (
    tester,
  ) async {
    final gateway = await gatewayWith();
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'E1'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medalhas'));
    await tester.pumpAndSettle();
    expect(find.byType(EditionScreen), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
  });
}
