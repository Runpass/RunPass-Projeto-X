import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/br_locations.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/edition_requests.dart';
import 'package:runpass/identity_gateway.dart';

Map<String, dynamic> entry(String id, {bool archived = false}) => {
  'id': id,
  'name': 'Corrida $id',
  'date': '2026-09-01',
  'city': 'São Paulo',
  'state': 'SP',
  'status': archived ? 'archived' : 'past',
  'version': 1,
  'description': 'Dados sintéticos para desenvolvimento.',
  'distances': [
    {'id': '5k', 'kilometers': 5},
    {'id': '10k', 'kilometers': 10},
  ],
};

Future<IdentityGateway> signed(
  JsonTransport handler, {
  String api = 'https://api.example',
  ByteTransport byteTransport = sendBytes,
}) async {
  final gateway = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse(api),
    clientId: 'synthetic',
    byteTransport: byteTransport,
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      return handler(uri, method, headers, body);
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return gateway;
}

Future<void> revealInEdition(WidgetTester tester, Finder target) async {
  final scroll = find
      .descendant(
        of: find.byType(EditionScreen),
        matching: find.byType(Scrollable),
      )
      .last;
  await tester.scrollUntilVisible(target, 200, scrollable: scroll);
  await tester.pumpAndSettle();
}

Future<void> reveal(
  WidgetTester tester,
  Finder target, {
  bool backwards = false,
}) async {
  final scroll = find
      .descendant(
        of: find.byType(CatalogScreen),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    target,
    backwards ? -160 : 160,
    scrollable: scroll,
  );
  await tester.pumpAndSettle();
}

const ratingLabels = [
  'Organização',
  'Percurso',
  'Kit',
  'Medalha',
  'Hidratação',
  'Estrutura',
  'Segurança',
  'Custo-benefício',
];

/// Toca numa estrela, rolando a lista (preguiçosa) até o centro dela ficar dentro da área visível da lista.
Future<void> tapStar(WidgetTester tester, String key) async {
  final list = find.byType(Scrollable).first;
  final star = find.byKey(Key(key));
  if (star.evaluate().isEmpty) {
    try {
      await tester.scrollUntilVisible(star, -200, scrollable: list);
    } on StateError {
      await tester.scrollUntilVisible(star, 200, scrollable: list);
    }
  }
  final area = tester.getRect(list);
  for (var i = 0; i < 30; i++) {
    final y = tester.getCenter(star).dy;
    if (y > area.top + 24 && y < area.bottom - 24) break;
    await tester.drag(list, Offset(0, y <= area.top + 24 ? 150 : -150));
    await tester.pump();
  }
  await tester.tap(star);
  await tester.pump();
}

Future<void> rateAll(WidgetTester tester, {int stars = 5, String? skip}) async {
  final list = find.byType(Scrollable).first;
  for (final label in ratingLabels) {
    if (label == skip) continue;
    final star = find.byKey(Key('rating-$label-$stars'));
    if (star.evaluate().isEmpty) {
      // A lista e preguicosa: procura para cima e, se nao achar, para baixo.
      try {
        await tester.scrollUntilVisible(star, -200, scrollable: list);
      } on StateError {
        await tester.scrollUntilVisible(star, 200, scrollable: list);
      }
    }
    await tester.ensureVisible(star);
    await tester.tap(star);
    await tester.pump();
  }
}

/// A busca por nome está sempre à vista (sem lupa): só garante que a tela terminou de carregar.
Future<void> openSearch(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

/// Estado e cidade pelo mesmo seletor do editar perfil; aceitar o padrão escolhe Acre / Acrelândia.
Future<void> pickFilterLocation(WidgetTester tester) async {
  final field = find.byKey(const Key('filter-location'));
  await reveal(tester, field, backwards: true);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('location-done')));
  await tester.pumpAndSettle();
}

/// O nome é o único campo obrigatório do formulário de filtros.
Future<void> fillName(WidgetTester tester, [String name = 'Corrida']) async {
  final field = find.widgetWithText(TextFormField, 'Buscar corridas');
  await reveal(tester, field, backwards: true);
  await tester.enterText(field, name);
}

/// Escolhe o tempo no seletor de rolagem (horas, minutos e segundos) e confirma.
Future<void> pickTime(
  WidgetTester tester, {
  int hours = 0,
  int minutes = 0,
  int seconds = 0,
}) async {
  await tester.ensureVisible(find.byKey(const Key('time-field')));
  await tester.tap(find.byKey(const Key('time-field')));
  await tester.pumpAndSettle();
  final wheels = find.byType(CupertinoPicker);
  for (final (index, steps) in [(0, hours), (1, minutes), (2, seconds)]) {
    if (steps == 0) continue;
    await tester.drag(wheels.at(index), Offset(0, -32.0 * steps));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const Key('duration-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(draftFormCache.clear);

  test('rótulos dos status do pedido, inclusive aguardando a carga', () {
    expect(requestStatusLabel('pending'), 'Em análise pela equipe');
    expect(
      requestStatusLabel('awaiting_load'),
      contains('assim que a corrida entrar no catálogo'),
    );
    expect(requestStatusLabel('outro'), 'Situação desconhecida');
  });
  priorityOrderTests();
  defaultOrderTests();
  test('query parameters preserve stage and encode filters without leaking into path', () async {
    final gateway = await signed((uri, method, headers, body) async {
      expect(uri.path, '/dev/editions');
      expect(uri.queryParameters['city'], 'São Paulo');
      expect(uri.queryParameters['cursor'], 'opaque+/=');
      expect(headers['Authorization'], 'Bearer synthetic');
      return const JsonReply(200, {'items': []});
    }, api: 'https://api.example/dev');
    await gateway.request(
      '/editions',
      query: {'city': 'São Paulo', 'cursor': 'opaque+/='},
    );
  });

  testWidgets(
    'list opens current detail and selects distance without creating a record',
    (tester) async {
      final paths = <String>[];
      final gateway = await signed((uri, method, headers, body) async {
        expect(method, 'GET');
        paths.add(uri.path);
        return uri.path == '/editions'
            ? JsonReply(200, {
                'items': [entry('A')],
              })
            : JsonReply(200, entry('A'));
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Corrida A'));
      await tester.tap(find.text('Corrida A'));
      await tester.pumpAndSettle();
      // O nome da corrida aparece só no banner, não repetido abaixo.
      expect(find.text('Corrida A'), findsOneWidget);
      await tester.tap(find.text('10K'));
      await tester.pumpAndSettle();
      expect(find.text('Distância selecionada.'), findsOneWidget);
      expect(
        paths.where(
          (c) =>
              c != '/me/participations' &&
              c != '/me/edition-requests' &&
              !c.endsWith('/comments'),
        ),
        [
          '/me', // cidade do perfil
          '/editions',
          '/me/race-plans', // marcas dos atalhos da lista
          '/editions/A',
          '/editions/A/reviews',
          '/editions/A/participants',
          '/editions/A/registrants',
          '/editions/A/photos',
          '/me/race-plans/A',
          '/editions/A/reviews',
        ],
      );
    },
  );

  testWidgets('existing draft in the edition is reopened instead of an error', (
    tester,
  ) async {
    final calls = <String>[];
    final gateway = await signed((uri, method, headers, body) async {
      calls.add('$method ${uri.path}');
      if (method == 'GET' && uri.path == '/me/participations') {
        expect(uri.queryParameters['state'], 'draft');
        return const JsonReply(200, {
          'items': [
            {
              'id': 'other',
              'editionId': 'B',
              'distanceId': '5k',
              'state': 'draft',
              'version': 1,
            },
            {
              'id': 'draft-9',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'draft',
              'version': 2,
            },
          ],
        });
      }
      if (method == 'GET') return JsonReply(200, entry('A'));
      return const JsonReply(409, {'code': 'PARTICIPATION_EXISTS'});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'A'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('10K'));
    await tester.pumpAndSettle();
    await revealInEdition(tester, find.text('Já corri'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Já corri'));
    await tester.pumpAndSettle();
    expect(find.text('Rascunho da participação'), findsOneWidget);
    expect(find.textContaining('Você já possui'), findsNothing);
    expect(calls, contains('GET /me/participations'));
  });

  testWidgets('archived edition remains visible without new selection', (
    tester,
  ) async {
    final gateway = await signed(
      (uri, method, headers, body) async =>
          JsonReply(200, entry('old', archived: true)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'old'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Edição arquivada:'), findsOneWidget);
    await tester.tap(find.text('10K'));
    await tester.pumpAndSettle();
    expect(find.text('Distância selecionada.'), findsNothing);
  });

  testWidgets('selected catalog distance creates and updates a private draft', (
    tester,
  ) async {
    final calls = <String>[];
    final gateway = await signed((uri, method, headers, body) async {
      calls.add('$method ${uri.path}');
      if (method == 'GET') return JsonReply(200, entry('A'));
      if (method == 'POST') {
        expect(body, {'editionId': 'A', 'distanceId': '10k'});
        expect(headers['Idempotency-Key'], isNotEmpty);
        return const JsonReply(201, {
          'id': 'draft-1',
          'editionId': 'A',
          'distanceId': '10k',
          'state': 'draft',
          'version': 1,
        });
      }
      expect(body?['expectedVersion'], 1);
      expect(body?['timeSeconds'], 3600);
      return const JsonReply(200, {
        'id': 'draft-1',
        'editionId': 'A',
        'distanceId': '10k',
        'state': 'draft',
        'version': 2,
        'timeSeconds': 3600,
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'A'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('10K'));
    await tester.pumpAndSettle();
    await revealInEdition(tester, find.text('Já corri'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Já corri'));
    await tester.pumpAndSettle();
    expect(find.text('Rascunho da participação'), findsOneWidget);
    expect(find.textContaining('não gera medalha'), findsOneWidget);
    // Corrida já realizada: não há "Salvar rascunho"; o tempo segue junto quando a participação é concluída.
    await pickTime(tester, hours: 1);
    expect(find.text('Salvar rascunho'), findsNothing);
    expect(find.text('Rascunho salvo. Nada foi publicado.'), findsNothing);
    expect(
      calls.where(
        (c) =>
            !c.contains('/me/participations') &&
            !c.contains('/me/edition-requests') &&
            !c.endsWith('/comments') &&
            !c.endsWith('/image'),
      ),
      [
        'GET /editions/A',
        'GET /editions/A/reviews',
        'GET /editions/A/participants',
        'GET /editions/A/registrants',
        'GET /editions/A/photos',
        'GET /me/race-plans/A',
        'GET /editions/A/reviews',
        'POST /participations',
        'GET /editions/A',
      ],
    );
  });

  testWidgets(
    'validated photo and eight ratings complete the draft vertically',
    (tester) async {
      final calls = <String>[];
      Map<String, dynamic>? completion;
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
          calls.add('$method ${uri.path}');
          if (uri.path == '/uploads') {
            return const JsonReply(201, {
              'uploadId': 'upload-1',
              'uploadUrl': 'https://private.example/upload-1',
              'uploadMethod': 'PUT',
              'uploadHeaders': {'Content-Type': 'image/jpeg'},
            });
          }
          if (uri.path.endsWith('/finalize')) {
            return const JsonReply(200, {
              'uploadId': 'upload-1',
              'state': 'valid',
              'imageReference': 'img-valid',
            });
          }
          if (!uri.path.endsWith('/complete')) {
            return const JsonReply(200, {'items': []});
          }
          completion = body;
          return const JsonReply(200, {
            'id': 'draft-1',
            'editionId': 'A',
            'distanceId': '10k',
            'state': 'completed',
            'version': 2,
            'medalImageReference': 'img-valid',
          });
        },
        byteTransport: (uri, method, headers, bytes) async {
          calls.add('$method signed-object');
          return 200;
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'draft-1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'draft',
              'version': 1,
            },
            photoSelector: () async => [0xff, 0xd8, 0xff, 0xd9],
          ),
        ),
      );
      await tester.tap(find.text('Selecionar foto'));
      await tester.pumpAndSettle();
      expect(
        find.text('Imagem validada para uso na conclusão.'),
        findsOneWidget,
      );

      final declaration = find.text('Declaro que concluí esta corrida');
      final list = find.byType(Scrollable).first;
      final finish = find.text('Concluir participação');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      // A avaliação é opcional: sem notas, concluir já está habilitado (avalia depois).
      expect(find.byKey(const Key('ratings-partial-hint')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Concluir participação'),
            )
            .onPressed,
        isNotNull,
      );
      // Notas pela metade (7 de 8): tudo ou nada, então concluir fica desabilitado e avisa.
      await rateAll(tester, skip: 'Segurança');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      expect(find.byKey(const Key('ratings-partial-hint')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Concluir participação'),
            )
            .onPressed,
        isNull,
      );
      await tapStar(tester, 'rating-Segurança-4');
      await tester.pump();
      await tester.scrollUntilVisible(declaration, 200, scrollable: list);
      await tester.tap(declaration);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      await tester.ensureVisible(finish);
      await tester.tap(finish);
      await tester.pumpAndSettle();

      expect(completion?['declaredCompleted'], true);
      expect((completion?['ratings'] as Map)['safety'], 4);
      expect((completion?['ratings'] as Map).length, 8);
      expect(completion?['medalImageReference'], 'img-valid');
      expect(find.textContaining('Participação concluída'), findsWidgets);
      expect(find.text('Salvar rascunho'), findsNothing);
      expect(find.text('Selecionar foto'), findsNothing);
      expect(find.textContaining('Privado · não gera medalha'), findsNothing);
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
      expect(
        calls.where(
          (c) =>
              !c.contains('/me/participations') &&
              !c.contains('/me/edition-requests') && // medalhas provisórias
              !c.endsWith('/image') &&
              c != 'GET /me',
        ),
        [
          'GET /editions/A',
          'POST /uploads',
          'PUT signed-object',
          'POST /uploads/upload-1/finalize',
          'POST /participations/draft-1/complete',
        ],
      );
    },
  );

  testWidgets(
    'concluir grava antes o tempo escolhido no temporizador (sem Salvar rascunho)',
    (tester) async {
      final calls = <String>[];
      Map<String, dynamic>? patch;
      Map<String, dynamic>? completion;
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
          calls.add('$method ${uri.path}');
          if (uri.path == '/uploads') {
            return const JsonReply(201, {
              'uploadId': 'upload-1',
              'uploadUrl': 'https://private.example/upload-1',
              'uploadMethod': 'PUT',
              'uploadHeaders': {'Content-Type': 'image/jpeg'},
            });
          }
          if (uri.path.endsWith('/finalize')) {
            return const JsonReply(200, {
              'uploadId': 'upload-1',
              'state': 'valid',
              'imageReference': 'img-valid',
            });
          }
          if (uri.path == '/participations/draft-1' && method == 'PATCH') {
            patch = Map<String, dynamic>.from(body! as Map);
            return const JsonReply(200, {
              'id': 'draft-1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'draft',
              'version': 2,
              'timeSeconds': 2700,
            });
          }
          if (uri.path.endsWith('/complete')) {
            completion = Map<String, dynamic>.from(body! as Map);
            return const JsonReply(200, {
              'id': 'draft-1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'completed',
              'version': 3,
              'medalImageReference': 'img-valid',
            });
          }
          return const JsonReply(200, {'items': []});
        },
        byteTransport: (uri, method, headers, bytes) async => 200,
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'draft-1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'draft',
              'version': 1,
            },
            photoSelector: () async => [0xff, 0xd8, 0xff, 0xd9],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Salvar rascunho'), findsNothing);
      await pickTime(tester, minutes: 45);
      await tester.tap(find.text('Selecionar foto'));
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      final declaration = find.text('Declaro que concluí esta corrida');
      final finish = find.text('Concluir participação');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      await rateAll(tester, skip: 'Segurança');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      await tapStar(tester, 'rating-Segurança-4');
      await tester.pump();
      await tester.scrollUntilVisible(declaration, 200, scrollable: list);
      await tester.tap(declaration);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      await tester.ensureVisible(finish);
      await tester.tap(finish);
      await tester.pumpAndSettle();
      // O tempo foi gravado (PATCH) ANTES de concluir, com a versão certa.
      expect(patch?['timeSeconds'], 2700);
      expect(patch?['expectedVersion'], 1);
      expect(completion?['expectedVersion'], 2);
      final order = calls
          .where((c) => c.contains('draft-1') && !c.endsWith('/image'))
          .toList();
      expect(order, [
        'PATCH /participations/draft-1',
        'POST /participations/draft-1/complete',
      ]);
      // Ao concluir, a pilha é zerada: a prateleira abre nova (com a medalha) e sem tela velha por baixo.
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
      expect(
        tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
        isFalse,
      );
    },
  );

  testWidgets('protected catalog error does not show results', (tester) async {
    final gateway = await signed(
      (uri, method, headers, body) async =>
          const JsonReply(403, {'code': 'BETA_ADMISSION_REQUIRED'}),
    );
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await reveal(
      tester,
      find.text('Sua conta ainda não foi liberada para consultar as corridas.'),
    );
    expect(
      find.text('Sua conta ainda não foi liberada para consultar as corridas.'),
      findsOneWidget,
    );
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('completed participation edits review and can be deleted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    final gateway = await signed((uri, method, headers, body) async {
      calls.add('$method ${uri.path}');
      if (method == 'GET') {
        return const JsonReply(200, {
          'participationId': 'done-1',
          'version': 1,
          'ratings': {
            'organization': 5,
            'course': 5,
            'kit': 5,
            'medal': 5,
            'hydration': 5,
            'facilities': 5,
            'safety': 5,
            'valueForMoney': 5,
          },
          'moderationState': 'valid',
          'comment': 'Anterior',
        });
      }
      if (method == 'PUT') {
        expect(body?['expectedVersion'], 1);
        expect(body?['comment'], isNull);
        return JsonReply(200, {
          ...body!,
          'participationId': 'done-1',
          'version': 2,
          'moderationState': 'valid',
        });
      }
      if (method == 'DELETE') {
        expect(uri.queryParameters['expectedVersion'], '2');
        return const JsonReply(202, {
          'operationId': 'erase-1',
          'state': 'pending',
          'publiclyHidden': true,
        });
      }
      return const JsonReply(200, {
        'id': 'done-1',
        'state': 'completed',
        'version': 3,
        'showTime': false,
        'showPlacement': true,
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ParticipationDraftScreen(
          gateway: gateway,
          initial: const {
            'id': 'done-1',
            'state': 'completed',
            'version': 2,
            'showTime': true,
            'showPlacement': true,
          },
        ),
      ),
    );
    // A avaliação se edita na própria tela da medalha, sem abrir outra, e grava junto com "Salvar dados".
    await tester.scrollUntilVisible(
      find.byKey(const Key('review-comment-inline')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Editar avaliação'), findsNothing);
    expect(
      find.text('Salvar avaliação'),
      findsNothing,
    ); // so Salvar dados e Excluir embaixo
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('review-comment-inline')))
          .controller!
          .text,
      'Anterior', // ja vem com o que enviei
    );
    await tester.scrollUntilVisible(
      find.text('Excluir participação'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Salvar dados da corrida'), findsOneWidget);
    await tester.ensureVisible(find.text('Excluir participação'));
    await tester.tap(find.text('Excluir participação'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Excluir participação').last);
    await tester.pumpAndSettle();
    // Volta para a lista de medalhas na hora, com "Desfazer"; o DELETE só vai depois da janela.
    expect(find.byType(MedalCollectionScreen), findsOneWidget);
    expect(find.textContaining('Participação excluída'), findsOneWidget);
    expect(find.byKey(const Key('undo-delete')), findsOneWidget);
    expect(calls.contains('DELETE /participations/done-1'), isFalse);
    await tester.pump(const Duration(seconds: 7)); // fecha a janela do Desfazer
    await tester.pumpAndSettle();
    // O DELETE foi enviado uma vez, so depois da janela do Desfazer.
    expect(calls.where((c) => c == 'DELETE /participations/done-1').length, 1);
  });

  testWidgets(
    'Salvar dados da corrida grava também a avaliação mexida e leva para Medalhas',
    (tester) async {
      final calls = <String>[];
      Map<String, dynamic>? put;
      final gateway = await signed((uri, method, headers, body) async {
        calls.add('$method ${uri.path}');
        if (method == 'GET' && uri.path.endsWith('/review')) {
          return const JsonReply(200, {
            'participationId': 'done-1',
            'version': 4,
            'ratings': {
              'organization': 5,
              'course': 5,
              'kit': 5,
              'medal': 5,
              'hydration': 5,
              'facilities': 5,
              'safety': 5,
              'valueForMoney': 5,
            },
            'moderationState': 'valid',
            'comment': 'Anterior',
          });
        }
        if (method == 'PUT') {
          put = Map<String, dynamic>.from(body! as Map);
          return JsonReply(200, {
            ...put!,
            'participationId': 'done-1',
            'version': 5,
            'moderationState': 'valid',
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'done-1',
              'state': 'completed',
              'version': 2,
              'showTime': true,
              'showPlacement': true,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('review-comment-inline')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('review-comment-inline')),
        'Mudei de ideia',
      );
      // Muda a nota do Kit para 2 (a tela tem o campo de avaliação já editável).
      final kit = find.byWidgetPredicate(
        (w) => w is RatingInput && w.label == 'Kit',
      );
      await tester.scrollUntilVisible(
        kit,
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      tester.widget<RatingInput>(kit).onChanged!(2);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('save-data')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byKey(const Key('save-data')));
      await tester.tap(find.byKey(const Key('save-data')));
      await tester.pumpAndSettle();
      expect(put?['expectedVersion'], 4);
      expect(put?['comment'], 'Mudei de ideia');
      expect((put?['ratings'] as Map)['kit'], 2);
      expect((put?['ratings'] as Map)['course'], 5);
      // Os dados da corrida nao mudaram: nao ha PATCH. Vai para Medalhas.
      expect(calls.where((c) => c.startsWith('PATCH')), isEmpty);
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
      expect(find.text('Dados da corrida salvos.'), findsOneWidget);
    },
  );

  testWidgets(
    'editar a avaliação de uma medalha concluída: "mesma nota para todos" vale para os 8 critérios e grava com Salvar dados',
    (tester) async {
      Map<String, dynamic>? put;
      final gateway = await signed((uri, method, headers, body) async {
        if (method == 'GET' && uri.path.endsWith('/review')) {
          return const JsonReply(200, {
            'participationId': 'done-1',
            'version': 4,
            'ratings': {
              'organization': 5,
              'course': 2,
              'kit': 3,
              'medal': 5,
              'hydration': 4,
              'facilities': 1,
              'safety': 5,
              'valueForMoney': 4,
            },
            'moderationState': 'valid',
          });
        }
        if (method == 'PUT') {
          put = Map<String, dynamic>.from(body! as Map);
          return JsonReply(200, {
            ...put!,
            'participationId': 'done-1',
            'version': 5,
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'done-1',
              'state': 'completed',
              'version': 2,
              'showTime': true,
              'showPlacement': true,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('same-rating-3')),
        300,
        scrollable: list,
      );
      await tester.ensureVisible(find.byKey(const Key('same-rating-3')));
      await tester.tap(find.byKey(const Key('same-rating-3')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('save-data')),
        300,
        scrollable: list,
      );
      await tester.ensureVisible(find.byKey(const Key('save-data')));
      await tester.tap(find.byKey(const Key('save-data')));
      await tester.pumpAndSettle();
      expect((put?['ratings'] as Map).length, 8);
      expect((put?['ratings'] as Map).values.every((v) => v == 3), isTrue);
    },
  );

  testWidgets(
    'tela "Editar avaliação" (aba da corrida): mesma nota para todos os critérios',
    (tester) async {
      Map<String, dynamic>? put;
      final gateway = await signed((uri, method, headers, body) async {
        if (method == 'GET') {
          return const JsonReply(200, {
            'participationId': 'done-1',
            'version': 1,
            'ratings': <String, dynamic>{
              'organization': 5,
              'course': 2,
              'kit': 3,
              'medal': 5,
              'hydration': 4,
              'facilities': 1,
              'safety': 5,
              'valueForMoney': 4,
            },
            'moderationState': 'valid',
          });
        }
        put = Map<String, dynamic>.from(body! as Map);
        return JsonReply(200, {
          ...put!,
          'participationId': 'done-1',
          'version': 2,
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ReviewEditScreen(gateway: gateway, participationId: 'done-1'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('same-rating-2')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Salvar avaliação'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Salvar avaliação'));
      await tester.pumpAndSettle();
      expect((put?['ratings'] as Map).values.every((v) => v == 2), isTrue);
    },
  );

  Future<IdentityGateway> draftGateway(
    String editionDate,
    void Function(Map<String, dynamic>? body) onComplete,
  ) => signed(byteTransport: (uri, method, headers, bytes) async => 200, (
    uri,
    method,
    headers,
    body,
  ) async {
    if (uri.path == '/editions/A') {
      return JsonReply(200, {...entry('A'), 'date': editionDate});
    }
    if (uri.path == '/uploads') {
      return const JsonReply(201, {
        'uploadId': 'u1',
        'uploadUrl': 'https://private.example/u1',
        'uploadMethod': 'PUT',
        'uploadHeaders': {'Content-Type': 'image/jpeg'},
      });
    }
    if (uri.path.endsWith('/finalize')) {
      return const JsonReply(200, {
        'uploadId': 'u1',
        'state': 'valid',
        'imageReference': 'img-valid',
      });
    }
    if (!uri.path.endsWith('/complete')) {
      return const JsonReply(200, {'items': []});
    }
    onComplete(body);
    return const JsonReply(200, {
      'id': 'd1',
      'editionId': 'A',
      'distanceId': '10k',
      'state': 'completed',
      'version': 2,
    });
  });

  Future<void> openDraftWithPhoto(
    WidgetTester tester,
    IdentityGateway gateway,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ParticipationDraftScreen(
          gateway: gateway,
          initial: const {
            'id': 'd1',
            'editionId': 'A',
            'distanceId': '10k',
            'state': 'draft',
            'version': 1,
          },
          photoSelector: () async => [0xff, 0xd8, 0xff, 0xd9],
        ),
      ),
    );
    await tester.pumpAndSettle();
    // A lista é montada sob demanda: rola até o botão existir, em vez de supor que já está na árvore.
    await tester.scrollUntilVisible(
      find.text('Selecionar foto'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selecionar foto'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'star ratings per criterion are sent when the race already happened',
    (tester) async {
      Map<String, dynamic>? completion;
      final gateway = await draftGateway(
        '2000-01-01',
        (body) => completion = body,
      );
      await openDraftWithPhoto(tester, gateway);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('rating-Kit-2')),
        200,
        scrollable: list,
      );
      await rateAll(tester, skip: 'Kit');
      await tester.scrollUntilVisible(
        find.byKey(const Key('rating-Kit-2')),
        -200,
        scrollable: list,
      );
      await tapStar(tester, 'rating-Kit-2');
      await tester.pump();
      final declaration = find.text('Declaro que concluí esta corrida');
      await tester.scrollUntilVisible(declaration, 200, scrollable: list);
      await tester.tap(declaration);
      await tester.pump();
      final finish = find.text('Concluir participação');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      await tester.ensureVisible(finish);
      await tester.tap(finish);
      await tester.pumpAndSettle();
      expect((completion?['ratings'] as Map)['kit'], 2);
      expect((completion?['ratings'] as Map)['course'], 5);
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
    },
  );

  testWidgets(
    'a race that has not happened yet stays as a draft without photo or rating',
    (tester) async {
      // Tela alta: com o campo de pace, o aviso fica mais abaixo na lista.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var completed = false;
      final gateway = await draftGateway('2999-01-01', (_) => completed = true);
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'd1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'draft',
              'version': 1,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('upcoming-notice')), findsOneWidget);
      expect(find.textContaining('Minhas corridas futuras'), findsOneWidget);
      // Segue editável como rascunho, mas não evolui: sem foto, avaliação nem conclusão.
      expect(find.text('Salvar rascunho'), findsOneWidget);
      expect(find.text('Selecionar foto'), findsNothing);
      expect(find.text('Concluir participação'), findsNothing);
      expect(completed, isFalse);
    },
  );

  Future<IdentityGateway> draftPhotoGateway(
    List<Map<String, dynamic>> patches,
  ) => signed(byteTransport: (uri, method, headers, bytes) async => 200, (
    uri,
    method,
    headers,
    body,
  ) async {
    if (uri.path == '/editions/A') {
      return JsonReply(200, {...entry('A'), 'date': '2000-01-01'});
    }
    if (uri.path == '/uploads') {
      return const JsonReply(201, {
        'uploadId': 'u1',
        'uploadUrl': 'https://private.example/u1',
        'uploadMethod': 'PUT',
        'uploadHeaders': {'Content-Type': 'image/jpeg'},
      });
    }
    if (uri.path.endsWith('/finalize')) {
      return const JsonReply(200, {
        'uploadId': 'u1',
        'state': 'valid',
        'imageReference': 'img-valid',
      });
    }
    if (uri.path == '/participations/d1' && method == 'PATCH') {
      patches.add(Map<String, dynamic>.from(body! as Map));
      return JsonReply(200, {
        'id': 'd1',
        'editionId': 'A',
        'distanceId': '10k',
        'state': 'draft',
        'version': 1 + patches.length + 1,
        if (patches.last.containsKey('medalImageReference'))
          'medalImageReference': patches.last['medalImageReference'],
      });
    }
    return const JsonReply(200, {'items': []});
  });

  Future<void> openDraftWithInitialPhoto(
    WidgetTester tester,
    IdentityGateway gateway,
  ) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ParticipationDraftScreen(
          gateway: gateway,
          initial: const {
            'id': 'd1',
            'editionId': 'A',
            'distanceId': '10k',
            'state': 'draft',
            'version': 1,
          },
          initialPhoto: const [0xff, 0xd8, 0xff, 0xd9],
          initialPhotoCropper: (context, bytes) async => bytes,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'foto da medalha já enviada no começo: sem "Selecionar foto"; há Concluir, Sair e continuar depois e Excluir',
    (tester) async {
      final gateway = await draftPhotoGateway([]);
      await openDraftWithInitialPhoto(tester, gateway);
      expect(
        find.text('Imagem validada para uso na conclusão.'),
        findsOneWidget,
      );
      expect(find.text('Selecionar foto'), findsNothing);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Excluir rascunho'),
        300,
        scrollable: list,
      );
      expect(find.text('Concluir participação'), findsOneWidget);
      expect(find.byKey(const Key('save-draft')), findsOneWidget);
      expect(find.text('Sair e continuar depois'), findsOneWidget);
      expect(find.text('Excluir rascunho'), findsOneWidget);
    },
  );

  testWidgets(
    'Sair e continuar depois grava os dados e a foto da medalha, não conclui e volta para Medalhas',
    (tester) async {
      final patches = <Map<String, dynamic>>[];
      final gateway = await draftPhotoGateway(patches);
      await openDraftWithInitialPhoto(tester, gateway);
      await tester.enterText(
        find.widgetWithText(TextField, 'Colocação (opcional)'),
        '12',
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('save-draft')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('save-draft')));
      await tester.pumpAndSettle();
      expect(patches.first['placement'], 12);
      expect(patches.last['medalImageReference'], 'img-valid');
      expect(patches.every((p) => !p.containsKey('declaredCompleted')), isTrue);
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
      expect(find.byType(ParticipationDraftScreen), findsNothing);
      expect(
        find.text(
          'Rascunho salvo. As notas e o comentário ficam neste aparelho. Nada foi publicado.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('a race already in my list is marked and opens my record', (
    tester,
  ) async {
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/me/participations') {
        return const JsonReply(200, {
          'items': [
            {
              'id': 'mine-1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'draft',
              'version': 1,
            },
            {
              'id': 'gone',
              'editionId': 'B',
              'distanceId': '5k',
              'state': 'deleted',
              'version': 3,
            },
          ],
        });
      }
      if (uri.path == '/editions') {
        return JsonReply(200, {
          'items': [entry('A'), entry('B')],
        });
      }
      return JsonReply(200, entry('A'));
    });
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    // Corrida já registrada: a ação "Já corri" vira "Meu registro", marcada.
    await reveal(tester, find.text('Meu registro'));
    expect(find.text('Meu registro'), findsOneWidget);
    await tester.ensureVisible(find.text('Corrida A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Corrida A'));
    await tester.pumpAndSettle();
    // Tocar abre a página da corrida (informações e avaliações), não uma pergunta.
    expect(find.text('Corrida já cadastrada'), findsNothing);
    expect(find.byType(EditionScreen), findsOneWidget);
    await revealInEdition(tester, find.byKey(const Key('already-mine')));
    expect(find.byKey(const Key('already-mine')), findsOneWidget);
    expect(find.text('Já corri'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Editar meu rascunho'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(TabBarView),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    await tester.ensureVisible(find.text('Editar meu rascunho'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Editar meu rascunho'));
    await tester.pumpAndSettle();
    expect(find.text('Rascunho da participação'), findsOneWidget);
  });

  testWidgets('the Corridas tab on a draft returns to the race list', (
    tester,
  ) async {
    final gateway = await draftGateway('2999-01-01', (_) {});
    await tester.pumpWidget(
      MaterialApp(
        home: ParticipationDraftScreen(
          gateway: gateway,
          initial: const {
            'id': 'd1',
            'editionId': 'A',
            'distanceId': '10k',
            'state': 'draft',
            'version': 1,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Corridas'));
    await tester.pumpAndSettle();
    expect(find.byType(CatalogScreen), findsOneWidget);
    expect(find.text('Rascunho da participação'), findsNothing);
  });

  testWidgets('an archived edition states why it is archived', (tester) async {
    final gateway = await signed(
      (uri, method, headers, body) async => JsonReply(200, {
        ...entry('old', archived: true),
        'archivedReason': 'cancelled',
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'old'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Edição arquivada: corrida cancelada pela organização.',
      ),
      findsOneWidget,
    );
  });

  test('error messages state the reason and what to do next', () {
    for (final code in [
      'EDITION_NOT_COMPLETABLE',
      'PARTICIPATION_EXISTS',
      'UPLOAD_UNAVAILABLE',
      'VERSION_CONFLICT',
      'SOMETHING_UNKNOWN',
    ]) {
      expect(
        catalogError(IdentityIssue(code)).length,
        greaterThan(50),
        reason: code,
      );
    }
    expect(archivedReasonLabel('unavailable'), contains('compra'));
    expect(archivedReasonLabel(null), isNull);
  });

  testWidgets(
    'a completed race lets me edit distance, time, placement and bib',
    (tester) async {
      Map<String, dynamic>? patched;
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions/A') return JsonReply(200, entry('A'));
        if (method == 'PATCH') {
          patched = body;
          return const JsonReply(200, {
            'id': 'done-1',
            'editionId': 'A',
            'distanceId': '5k',
            'state': 'completed',
            'version': 4,
            'timeSeconds': 5400,
          });
        }
        return const JsonReply(200, {});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'done-1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'completed',
              'version': 3,
              'timeSeconds': 3600,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Meus dados desta corrida'),
        200,
        scrollable: list,
      );
      // O tempo guardado aparece formatado.
      final timeField = find.byKey(const Key('time-field'));
      await tester.scrollUntilVisible(timeField, 200, scrollable: list);
      expect(
        find.descendant(of: timeField, matching: find.text('1:00:00')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('distance-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5K').last);
      await tester.pumpAndSettle();
      await pickTime(tester, minutes: 30); // parte de 1:00:00
      await tester.enterText(
        find.widgetWithText(TextField, 'Número de peito (opcional)'),
        '4821',
      );
      // 1:30:00 em 5 km: o pace é calculado sozinho (18:00 por km) e não se digita.
      expect(
        tester.widget<TextField>(find.byKey(const Key('pace-field'))).readOnly,
        isTrue,
      );
      expect(find.text('Pace (calculado)'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Salvar dados da corrida'),
        200,
        scrollable: list,
      );
      await tester.ensureVisible(find.text('Salvar dados da corrida'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salvar dados da corrida'));
      await tester.pumpAndSettle();
      expect(patched?['expectedVersion'], 3);
      expect(patched?['distanceId'], '5k');
      expect(patched?['timeSeconds'], 5400);
      expect(patched?['paceSecondsPerKm'], 1080);
      expect(patched?['bibNumber'], '4821');
      // Depois de salvar, vai para a tela de Medalhas (com o aviso lá).
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
      expect(find.byType(ParticipationDraftScreen), findsNothing);
      expect(find.text('Dados da corrida salvos.'), findsOneWidget);
    },
  );

  test('pace calculado pelo tempo e pela distância', () {
    expect(paceFromTime('1:00:00', 10), 360); // 6:00 por km
    expect(paceFromTime('0:25:00', 5), 300); // 5:00 por km
    expect(paceFromTime('1:52:30', 21.0975), 320); // arredonda: 319,9
    expect(paceFromTime('', 10), isNull); // sem tempo
    expect(paceFromTime('1:00:00', null), isNull); // sem distância
    expect(paceFromTime('1:00:00', 0), isNull);
    expect(
      paceFromTime('0:00:30', 10),
      isNull,
    ); // 3 s por km: fora do que se aceita
    expect(formatPace(paceFromTime('0:25:00', 5)!), '5:00/km');
  });

  test('duration parser accepts h:mm:ss, mm:ss and seconds', () {
    expect(parseDuration('1:30:00'), 5400);
    expect(parseDuration('45:10'), 2710);
    expect(parseDuration('3600'), 3600);
    expect(parseDuration(''), isNull);
    expect(parseDuration('1:75:00'), -1);
    expect(parseDuration('abc'), -1);
    expect(parseDuration('0'), -1);
  });

  testWidgets('the reviews tab shows the review I already registered', (
    tester,
  ) async {
    // A minha avaliação fica abaixo do resumo geral: janela alta para ela ser construída.
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/me/participations') {
        return const JsonReply(200, {
          'items': [
            {
              'id': 'done-1',
              'editionId': 'A',
              'distanceId': '10k',
              'state': 'completed',
              'version': 2,
            },
          ],
        });
      }
      if (uri.path == '/participations/done-1/review') {
        return const JsonReply(200, {
          'participationId': 'done-1',
          'version': 1,
          'ratings': {
            'organization': 5,
            'course': 4,
            'kit': 3,
            'medal': 5,
            'hydration': 4,
            'facilities': 2,
            'safety': 5,
            'valueForMoney': 4,
          },
          'comment': 'Ótima corrida',
        });
      }
      if (uri.path.endsWith('/reviews')) return const JsonReply(404, {});
      return JsonReply(200, entry('A'));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: EditionScreen(gateway: gateway, editionId: 'A'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Avalia').first);
    await tester.pumpAndSettle();
    expect(find.text('Minha avaliação'), findsOneWidget);
    expect(find.text('“Ótima corrida”'), findsOneWidget);
    expect(find.text('Editar avaliação'), findsOneWidget);
  });

  testWidgets('a completed participation shows the review I saved', (
    tester,
  ) async {
    final gateway = await signed((uri, method, headers, body) async {
      return const JsonReply(200, {
        'participationId': 'done-1',
        'version': 1,
        'ratings': {
          'organization': 5,
          'course': 4,
          'kit': 3,
          'medal': 5,
          'hydration': 4,
          'facilities': 2,
          'safety': 5,
          'valueForMoney': 4,
        },
        'comment': 'Percurso bonito',
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ParticipationDraftScreen(
          gateway: gateway,
          initial: const {
            'id': 'done-1',
            'editionId': 'A',
            'distanceId': '10k',
            'state': 'completed',
            'version': 3,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Minha avaliação'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Minha avaliação'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Hidratação'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Hidratação'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('review-comment-inline')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('review-comment-inline')))
          .controller!
          .text,
      'Percurso bonito',
    );
  });

  testWidgets('detalhe so afirma inscricao quando a fonte informou', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> open(Map<String, dynamic> extra) async {
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions/E1') {
          return JsonReply(200, {...entry('A'), 'id': 'E1', ...extra});
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(const SizedBox()); // descarta o estado anterior
      await tester.pumpWidget(
        MaterialApp(
          home: EditionScreen(gateway: gateway, editionId: 'E1'),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open({});
    expect(find.text('Situação das inscrições não informada.'), findsOneWidget);
    expect(find.byKey(const Key('verified-info')), findsNothing);
    await open({
      'registrationStatus': 'open',
      'lastVerifiedAt': '2026-11-06T12:00:00Z',
      'venue': 'Parque Exemplo',
    });
    expect(find.text('Inscrições abertas.'), findsOneWidget);
    expect(find.text('Informação conferida em 06/11/2026.'), findsOneWidget);
    expect(find.text('Local: Parque Exemplo'), findsOneWidget);
  });

  testWidgets('detalhe mostra site e compra so com links https validos', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opened = <Uri>[];
    final original = linkOpener;
    linkOpener = (uri) async {
      opened.add(uri);
      return true;
    };
    addTearDown(() => linkOpener = original);
    Future<void> open(Map<String, dynamic> extra) async {
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions/E1') {
          return JsonReply(200, {...entry('A'), 'id': 'E1', ...extra});
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: EditionScreen(gateway: gateway, editionId: 'E1'),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open({});
    expect(find.byKey(const Key('link-compra')), findsNothing);
    expect(find.byKey(const Key('link-site')), findsNothing);

    // Esquemas perigosos, http puro e usuario/senha embutidos nunca viram botao.
    await open({
      'officialUrl': 'javascript:alert(1)',
      'registrationUrl': 'http://exemplo.test/inscricao',
    });
    expect(find.byKey(const Key('link-compra')), findsNothing);
    expect(find.byKey(const Key('link-site')), findsNothing);
    await open({'registrationUrl': 'https://user:senha@exemplo.test/x'});
    expect(find.byKey(const Key('link-compra')), findsNothing);

    await open({
      'officialUrl': 'https://corrida.exemplo.test/',
      'registrationUrl': 'https://ingressos.exemplo.test/e/1',
      'registrationStatus': 'open',
    });
    expect(find.text('Comprar inscrição'), findsOneWidget);
    expect(find.text('Site da corrida'), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-compra')));
    await tester.tap(find.byKey(const Key('link-site')));
    await tester.pump();
    expect(opened.map((u) => u.toString()), [
      'https://ingressos.exemplo.test/e/1',
      'https://corrida.exemplo.test/',
    ]);

    // Inscricao encerrada: o botao nao convida a comprar.
    await open({
      'registrationUrl': 'https://ingressos.exemplo.test/e/1',
      'registrationStatus': 'closed',
    });
    expect(find.text('Comprar inscrição'), findsNothing);
    expect(find.text('Página de inscrição'), findsOneWidget);

    // Falha ao abrir avisa a pessoa em vez de ficar em silencio.
    linkOpener = (uri) async => false;
    await tester.tap(find.byKey(const Key('link-compra')));
    await tester.pump();
    expect(find.text('Não foi possível abrir o link.'), findsOneWidget);
  });

  testWidgets(
    'detalhe mostra Instagram e Facebook só de perfis das próprias redes',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <Uri>[];
      final original = linkOpener;
      linkOpener = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => linkOpener = original);
      Future<void> open(Map<String, dynamic> extra) async {
        final gateway = await signed((uri, method, headers, body) async {
          if (uri.path == '/editions/E1') {
            return JsonReply(200, {...entry('A'), 'id': 'E1', ...extra});
          }
          return const JsonReply(200, {'items': []});
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: EditionScreen(gateway: gateway, editionId: 'E1'),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open({});
      expect(find.byKey(const Key('link-instagram')), findsNothing);
      expect(find.byKey(const Key('link-facebook')), findsNothing);
      // Outro domínio, http e esquemas perigosos nunca viram botão.
      await open({
        'instagramUrl': 'https://exemplo.org/instagram/corrida/',
        'facebookUrl': 'http://www.facebook.com/corridaexemplo',
      });
      expect(find.byKey(const Key('link-instagram')), findsNothing);
      expect(find.byKey(const Key('link-facebook')), findsNothing);
      await open({'instagramUrl': 'javascript:alert(1)'});
      expect(find.byKey(const Key('link-instagram')), findsNothing);
      await open({
        'instagramUrl': 'https://www.instagram.com/corrida_exemplo/',
        'facebookUrl': 'https://www.facebook.com/corridaexemplo',
      });
      expect(find.text('Ver no Instagram'), findsOneWidget);
      expect(find.text('Ver no Facebook'), findsOneWidget);
      await tester.tap(find.byKey(const Key('link-instagram')));
      await tester.tap(find.byKey(const Key('link-facebook')));
      await tester.pump();
      expect(opened.map((u) => u.toString()), [
        'https://www.instagram.com/corrida_exemplo/',
        'https://www.facebook.com/corridaexemplo',
      ]);
    },
  );

  group('busca por nome', () {
    testWidgets(
      'a lupa abre só o campo de nome e a opção de incluir uma corrida',
      (tester) async {
        tester.view.physicalSize = const Size(800, 3000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final calls = <Map<String, String>>[];
        final gateway = await signed((uri, method, headers, body) async {
          if (uri.path == '/editions') calls.add(uri.queryParameters);
          return JsonReply(200, {
            'items': [entry('A')],
          });
        });
        await tester.pumpWidget(
          MaterialApp(home: CatalogScreen(gateway: gateway)),
        );
        await tester.pumpAndSettle();
        // O campo está sempre à vista, sem lupa; o cadastro manual só aparece quando a busca não acha.
        expect(find.byKey(const Key('catalog-name-search')), findsOneWidget);
        expect(find.byIcon(Icons.search_rounded), findsNothing);
        expect(find.byKey(const Key('catalog-request-empty')), findsNothing);
        // Sem frase livre; os filtros são as três pílulas: perto de mim, ano e localização.
        expect(find.byKey(const Key('catalog-phrase')), findsNothing);
        expect(find.text('Encontre sua próxima conquista'), findsNothing);
        expect(find.byKey(const Key('filter-near-me')), findsOneWidget);
        expect(find.byKey(const Key('filter-year')), findsOneWidget);
        expect(find.byKey(const Key('filter-location')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('catalog-name-search')),
          'meia',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        // A busca por nome vale para o catálogo todo: sem cidade do perfil nem janela de 20 dias.
        expect(calls.last, {'q': 'meia', 'limit': '20'});
        // Limpar a busca volta à lista padrão.
        await tester.tap(find.byKey(const Key('catalog-search-clear')));
        await tester.pumpAndSettle();
        expect(calls.last['dateFrom'], upcomingRange().from);
        expect(calls.last.containsKey('q'), isFalse);
      },
    );

    testWidgets(
      'incluir uma corrida abre o pedido de cadastro com o nome digitado',
      (tester) async {
        tester.view.physicalSize = const Size(800, 3000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final gateway = await signed((uri, method, headers, body) async {
          return const JsonReply(200, {'items': []});
        });
        await tester.pumpWidget(
          MaterialApp(home: CatalogScreen(gateway: gateway)),
        );
        await tester.pumpAndSettle();
        await openSearch(tester);
        await tester.enterText(
          find.byKey(const Key('catalog-name-search')),
          'Corrida Nova',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        // Sem resultado: habilita o cadastro manual, já com o nome digitado.
        await tester.tap(find.byKey(const Key('catalog-request-empty')));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(TextFormField, 'Corrida Nova'),
          findsOneWidget,
        );
      },
    );
  });

  group('pedido de prova ausente', () {
    void bigScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<void> fillRequest(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const Key('request-name')),
        '  Night Run  ',
      );
      await tester.enterText(
        find.byKey(const Key('request-date')),
        '14/03/2027',
      );
      await tester.enterText(
        find.byKey(const Key('request-distanceKm')),
        '10,5',
      );
      // A cidade nao vem pronta (B8): escolhe na roda, primeiro estado e primeira cidade.
      await tester.ensureVisible(find.byKey(const Key('request-location')));
      await tester.tap(find.byKey(const Key('request-location')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location-done')));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'o catalogo oferece o pedido e envia so o que a pessoa preencheu',
      (tester) async {
        bigScreen(tester);
        final posts = <Map<String, dynamic>>[];
        final gateway = await signed((uri, method, headers, body) async {
          if (uri.path == '/edition-requests' && method == 'POST') {
            posts.add(body!);
            return JsonReply(201, {
              'id': 'r1',
              'version': 1,
              'status': 'pending',
              'details': body,
            });
          }
          return const JsonReply(200, {'items': []});
        });
        await tester.pumpWidget(
          MaterialApp(home: CatalogScreen(gateway: gateway)),
        );
        await tester.pumpAndSettle();
        // Um só "+" no topo: incluir uma corrida ou ver as solicitações.
        expect(find.byKey(const Key('catalog-request-new')), findsOneWidget);
        await tester.tap(find.byKey(const Key('catalog-request-new')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('catalog-request-mine')), findsOneWidget);
        await tester.tap(find.byKey(const Key('catalog-request-new-item')));
        await tester.pumpAndSettle();
        expect(find.text('Pedir cadastro da corrida'), findsWidgets);
        await fillRequest(tester);
        await tester.tap(find.byKey(const Key('request-submit')));
        await tester.pumpAndSettle();
        final firstUf = brStates.first.uf;
        expect(posts.single, {
          'name': 'Night Run',
          'date': '2027-03-14',
          'city': brCitiesByState[firstUf]!.first,
          'state': firstUf,
          'distanceKm': 10.5,
        });
        expect(find.textContaining('Pedido enviado'), findsOneWidget);
      },
    );

    testWidgets('campos invalidos nao chegam ao servidor', (tester) async {
      bigScreen(tester);
      var calls = 0;
      final gateway = await signed((uri, method, headers, body) async {
        if (method == 'POST') calls++;
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: EditionRequestFormScreen(gateway: gateway)),
      );
      await tester.tap(find.byKey(const Key('request-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Preencha este campo.'), findsNWidgets(3));
      await tester.enterText(find.byKey(const Key('request-name')), 'X');
      await tester.enterText(
        find.byKey(const Key('request-date')),
        '31/02/2027',
      );
      await tester.enterText(find.byKey(const Key('request-distanceKm')), '-3');
      await tester.enterText(
        find.byKey(const Key('request-officialUrl')),
        'http://x.org',
      );
      await tester.tap(find.byKey(const Key('request-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('Use uma data válida no formato DD/MM/AAAA.'),
        findsOneWidget,
      );
      expect(find.textContaining('Informe a distância em km'), findsOneWidget);
      expect(find.textContaining('https://'), findsWidgets);
      expect(calls, 0);
    });

    testWidgets('erro do servidor diz o motivo e o que fazer', (tester) async {
      bigScreen(tester);
      final gateway = await signed((uri, method, headers, body) async {
        return const JsonReply(409, {'code': 'TOO_MANY_PENDING_REQUESTS'});
      });
      await tester.pumpWidget(
        MaterialApp(home: EditionRequestFormScreen(gateway: gateway)),
      );
      await fillRequest(tester);
      await tester.tap(find.byKey(const Key('request-submit')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Você já tem 10 pedidos aguardando análise'),
        findsOneWidget,
      );
    });

    testWidgets(
      'minhas solicitacoes mostram a situacao e permitem corrigir o rejeitado',
      (tester) async {
        bigScreen(tester);
        final calls = <String>[];
        Map<String, dynamic> request(
          String id,
          String status, {
          Map<String, dynamic>? extra,
        }) => {
          'id': id,
          'version': status == 'rejected' ? 2 : 1,
          'status': status,
          'details': {
            'name': 'Prova $id',
            'date': '2027-03-14',
            'city': 'São Paulo',
            'state': 'SP',
            'distanceKm': 10,
          },
          ...?extra,
        };
        final gateway = await signed((uri, method, headers, body) async {
          calls.add('$method ${uri.path}');
          if (uri.path == '/me/edition-requests') {
            return JsonReply(200, {
              'items': [
                request('a', 'pending'),
                request('b', 'rejected', extra: {'reason': 'Data não confere'}),
                request('c', 'linked', extra: {'linkedEditionId': 'E9'}),
              ],
            });
          }
          if (method == 'PATCH') {
            return JsonReply(
              200,
              request('b', 'rejected', extra: {'version': 3}),
            );
          }
          if (uri.path.endsWith('/resubmit')) {
            return JsonReply(200, request('b', 'pending'));
          }
          return const JsonReply(200, {'items': []});
        });
        await tester.pumpWidget(
          MaterialApp(home: MyEditionRequestsScreen(gateway: gateway)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Em análise pela equipe'), findsOneWidget);
        expect(find.text('Não aprovada'), findsOneWidget);
        expect(find.text('Motivo: Data não confere'), findsOneWidget);
        expect(find.textContaining('Esta corrida já existia'), findsOneWidget);
        expect(find.text('Ver a corrida no catálogo'), findsOneWidget);
        await tester.tap(find.text('Corrigir e reenviar'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('request-reason')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('request-date')),
          '21/03/2027',
        );
        await tester.tap(find.byKey(const Key('request-submit')));
        await tester.pumpAndSettle();
        expect(
          calls.where((c) => c.startsWith('PATCH') || c.contains('resubmit')),
          ['PATCH /edition-requests/b', 'POST /edition-requests/b/resubmit'],
        );
      },
    );
  });

  testWidgets(
    'ao abrir sem corridas há só a orientação de buscar; a busca sem resultado oferece pedir o cadastro',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await signed((uri, method, headers, body) async {
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Nenhuma corrida'), findsNothing);
      expect(find.byKey(const Key('catalog-request-empty')), findsNothing);
      // Tela não fica em branco: orienta a buscar pelo nome.
      expect(find.byKey(const Key('catalog-opening-hint')), findsOneWidget);
      // O campo está sempre à vista e sem lupa.
      expect(find.byKey(const Key('catalog-name-search')), findsOneWidget);
      expect(find.byIcon(Icons.search_rounded), findsNothing);
      await tester.enterText(
        find.byKey(const Key('catalog-name-search')),
        'Inexistente',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(
        find.text('Nenhuma corrida encontrada com esses filtros.'),
        findsOneWidget,
      );
      expect(
        find.text('Não encontrou? Cadastrar a corrida manualmente'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('catalog-request-empty')));
      await tester.pumpAndSettle();
      expect(find.text('Pedir cadastro da corrida'), findsWidgets);
      expect(find.byKey(const Key('request-submit')), findsOneWidget);
    },
  );

  testWidgets('com resultados nao ha atalho de pedido no fim da lista', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await signed((uri, method, headers, body) async {
      return JsonReply(200, {
        'items': [entry('A')],
      });
    });
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-request-empty')), findsNothing);
    // O atalho fixo do topo continua: nao depende de a lista estar vazia.
    expect(find.byKey(const Key('catalog-request-new')), findsOneWidget);
  });

  testWidgets(
    'a lista mantém a ordem do servidor (da mais antiga para a mais nova), sem ícones de ordem',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions') {
          return JsonReply(200, {
            'items': [
              {...entry('A'), 'id': 'EA', 'date': '2024-05-01'},
              {...entry('B'), 'id': 'EB', 'date': '2025-05-01'},
              {...entry('C'), 'id': 'EC', 'date': '2026-05-01'},
            ],
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      double top(String text) => tester
          .getTopLeft(find.textContaining(text))
          .dx; // mesma cidade: a ordem é da esquerda para a direita na faixa
      expect(top('Corrida A') < top('Corrida B'), isTrue);
      expect(top('Corrida B') < top('Corrida C'), isTrue);
      expect(find.byKey(const Key('catalog-sort')), findsNothing);
      expect(find.byKey(const Key('catalog-sort-rating')), findsNothing);
      expect(find.byKey(const Key('catalog-date-filter')), findsNothing);
    },
  );

  testWidgets(
    'falha passageira na lista: a tela tenta de novo sozinha uma vez',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var calls = 0;
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path != '/editions') return const JsonReply(200, {'items': []});
        calls++;
        // 3 recusas seguidas (o gateway já tenta 3 vezes) e depois responde.
        if (calls <= 3) {
          return const JsonReply(503, {'message': 'Service Unavailable'});
        }
        return JsonReply(200, {
          'items': [
            {...entry('A'), 'id': 'EA', 'date': '2026-05-01'},
          ],
        });
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pump(const Duration(seconds: 2));
      // Enquanto tenta de novo sozinha, não mostra a mensagem de erro.
      expect(find.byKey(const Key('catalog-error')), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(calls, 4);
      expect(find.byKey(const Key('catalog-error')), findsNothing);
      expect(find.textContaining('Corrida A'), findsOneWidget);
    },
  );

  testWidgets(
    'a lista traz 20 por vez e "Carregar mais" pede a próxima página com o mesmo limite',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <Map<String, String>>[];
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path != '/editions') return const JsonReply(200, {'items': []});
        calls.add(uri.queryParameters);
        final q = uri.queryParameters;
        if (q['cursor'] != null && q['limit'] != '20') {
          return const JsonReply(422, {'code': 'INVALID_CURSOR'});
        }
        if (q['cursor'] == 'c2') {
          return JsonReply(200, {
            'items': [
              {...entry('B'), 'id': 'EB', 'date': '2026-01-01'},
            ],
          });
        }
        return JsonReply(200, {
          'items': [
            {...entry('A'), 'id': 'EA', 'date': '2025-01-01'},
          ],
          'nextCursor': 'c2',
        });
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      // Só a primeira página: nada de carregar o resto em sequência.
      expect(calls.map((c) => c['limit']), ['20']);
      expect(find.textContaining('Corrida B'), findsNothing);
      await tester.tap(find.byKey(const Key('catalog-show-more')));
      await tester.pumpAndSettle();
      expect(calls.map((c) => c['limit']), ['20', '20']);
      expect(calls.last['cursor'], 'c2');
      expect(find.byKey(const Key('catalog-error')), findsNothing);
      expect(find.textContaining('Corrida A'), findsOneWidget);
      expect(find.textContaining('Corrida B'), findsOneWidget);
      expect(find.byKey(const Key('catalog-show-more')), findsNothing);
    },
  );

  testWidgets(
    'atalhos da lista: quero correr, inscrito e já corri sem abrir a corrida',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final plans = <String, String>{};
      final calls = <String>[];
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions') {
          return JsonReply(200, {
            'items': [
              {
                ...entry('A'),
                'id': 'EA',
                'status': 'upcoming',
                'date': '2099-05-01',
              },
              {
                ...entry('B'),
                'id': 'EB',
                'status': 'past',
                'date': '2020-05-01',
              },
            ],
          });
        }
        if (uri.path == '/me/race-plans' && method == 'GET') {
          return JsonReply(200, {
            'items': [
              for (final e in plans.entries)
                {'editionId': e.key, 'status': e.value, 'version': 1},
            ],
          });
        }
        if (uri.path.startsWith('/me/race-plans/')) {
          final id = uri.pathSegments.last;
          calls.add('$method $id ${body?['status'] ?? ''}');
          if (method == 'DELETE') {
            plans.remove(id);
            return const JsonReply(204, {});
          }
          plans[id] = body!['status'] as String;
          return JsonReply(200, {
            'editionId': id,
            'status': plans[id],
            'version': 1,
          });
        }
        if (uri.path == '/participations' && method == 'POST') {
          calls.add('POST ${body?['editionId']} ${body?['distanceId']}');
          return JsonReply(201, {
            'id': 'draft-1',
            'editionId': body?['editionId'],
            'distanceId': body?['distanceId'],
            'state': 'draft',
            'version': 1,
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      // Corrida futura: os três atalhos; corrida passada: só "já corri".
      expect(find.byKey(const Key('quick-wanted-EA')), findsOneWidget);
      expect(find.byKey(const Key('quick-registered-EA')), findsOneWidget);
      expect(find.byKey(const Key('quick-ran-EA')), findsOneWidget);
      expect(find.byKey(const Key('quick-wanted-EB')), findsNothing);
      expect(find.byKey(const Key('quick-registered-EB')), findsNothing);
      expect(find.byKey(const Key('quick-ran-EB')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quick-wanted-EA')));
      await tester.pumpAndSettle();
      expect(calls.last, 'PUT EA wanted');
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      await tester.tap(find.byKey(const Key('quick-registered-EA')));
      await tester.pumpAndSettle();
      expect(calls.last, 'PUT EA registered');
      expect(find.byIcon(Icons.favorite), findsNothing);
      await tester.tap(find.byKey(const Key('quick-registered-EA')));
      await tester.pumpAndSettle();
      expect(calls.last, 'DELETE EA ');
      // Sem abrir a corrida: nenhuma tela de detalhe foi aberta.
      expect(find.byType(EditionScreen), findsNothing);
    },
  );
}

void priorityOrderTests() {
  testWidgets(
    'as minhas corridas não passam mais na frente: a lista segue a ordem do servidor (da mais antiga para a mais nova)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Map<String, dynamic> race(String id, String date) => {
        ...entry(id),
        'id': 'E$id',
        'date': date,
        'status': 'upcoming',
      };
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions') {
          return JsonReply(200, {
            'items': [
              // O servidor já devolve da mais antiga para a mais nova.
              race('D', '2024-01-01'), // já corri, a mais antiga
              race('C', '2026-05-01'), // inscrito
              race('B', '2026-06-01'), // desejo
              race('F', '2026-07-01'), // desejo
              race('E', '2026-12-01'), // sem marca
              race('A', '2027-01-01'), // sem marca, a mais recente
            ],
          });
        }
        if (uri.path == '/me/participations') {
          return const JsonReply(200, {
            'items': [
              {
                'editionId': 'ED',
                'state': 'completed',
                'id': 'p1',
                'version': 1,
              },
            ],
          });
        }
        if (uri.path == '/me/race-plans') {
          return const JsonReply(200, {
            'items': [
              {'editionId': 'EB', 'status': 'wanted', 'version': 1},
              {'editionId': 'EC', 'status': 'registered', 'version': 1},
              {'editionId': 'EF', 'status': 'wanted', 'version': 1},
            ],
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      double top(String id) =>
          tester.getTopLeft(find.byKey(Key('quick-ran-E$id'))).dx;
      List<String> order() =>
          (['A', 'B', 'C', 'D', 'E', 'F']
            ..sort((a, b) => top(a).compareTo(top(b))));
      // Da mais antiga para a mais nova, sem pôr as minhas (D corri, C inscrito, B e F desejo) na frente.
      expect(order(), ['D', 'C', 'B', 'F', 'E', 'A']);
    },
  );
}

void defaultOrderTests() {
  testWidgets('por padrão a lista vem da data mais antiga para a mais nova', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final limits = <String?>[];
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions') {
        limits.add(uri.queryParameters['limit']);
        return JsonReply(200, {
          'items': [
            {...entry('A'), 'id': 'EA', 'date': '2024-05-01'},
            {...entry('B'), 'id': 'EB', 'date': '2026-05-01'},
          ],
        });
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(limits.first, '20');
    double top(String text) => tester.getTopLeft(find.textContaining(text)).dx;
    expect(top('Corrida A') < top('Corrida B'), isTrue);
  });

  testWidgets(
    'lista em faixas por cidade: rola na horizontal dentro da cidade, na vertical entre cidades',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions') {
          return JsonReply(200, {
            'items': [
              {
                ...entry('A'),
                'id': 'EA',
                'date': '2026-12-01',
                'city': 'Santos',
              },
              {...entry('B'), 'id': 'EB', 'date': '2026-12-02'},
              {...entry('C'), 'id': 'EC', 'date': '2026-12-03'},
            ],
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      // São Paulo (2 corridas) vem antes de Santos (1); cada cidade é uma faixa com título e contagem.
      final sp = find.byKey(const Key('catalog-city-São Paulo, SP'));
      final santos = find.byKey(const Key('catalog-city-Santos, SP'));
      expect(sp, findsOneWidget);
      expect(santos, findsOneWidget);
      expect(tester.getTopLeft(sp).dy < tester.getTopLeft(santos).dy, isTrue);
      expect(find.text('2 corridas'), findsOneWidget);
      expect(find.text('1 corrida'), findsOneWidget);
      // Na mesma cidade, lado a lado (mesma altura), da data mais próxima para a mais distante.
      final b = tester.getTopLeft(find.text('Corrida B'));
      final c = tester.getTopLeft(find.text('Corrida C'));
      expect(b.dy, c.dy);
      expect(b.dx < c.dx, isTrue);
      final row = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('catalog-row-São Paulo, SP')),
      );
      expect(row.scrollDirection, Axis.horizontal);
    },
  );

  testWidgets(
    'cartão da lista: ícone do link da prova só quando há link https',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <Uri>[];
      final original = linkOpener;
      linkOpener = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => linkOpener = original);
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions') {
          return JsonReply(200, {
            'items': [
              {...entry('A'), 'officialUrl': 'https://corrida.exemplo.test/'},
              {
                ...entry('B'),
                'registrationUrl': 'https://ingressos.exemplo.test/b',
              },
              {...entry('C'), 'officialUrl': 'javascript:alert(1)'},
            ],
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card-link-A')), findsOneWidget);
      expect(find.byKey(const Key('card-link-B')), findsOneWidget);
      expect(find.byKey(const Key('card-link-C')), findsNothing);
      await tester.tap(find.byKey(const Key('card-link-A')));
      await tester.tap(find.byKey(const Key('card-link-B')));
      await tester.pump();
      expect(opened.map((u) => u.toString()), [
        'https://corrida.exemplo.test/',
        'https://ingressos.exemplo.test/b',
      ]);
    },
  );
}
