import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

Future<void> openSearch(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('catalog-search-toggle')));
  await tester.pumpAndSettle();
}

void main() {
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
    'catalog filters and empty page keep continuation and append results',
    (tester) async {
      final calls = <Map<String, String>>[];
      final gateway = await signed((uri, method, headers, body) async {
        expect(uri.path, '/editions');
        calls.add(uri.queryParameters);
        if (uri.queryParameters['cursor'] == 'next') {
          return JsonReply(200, {
            'items': [entry('B')],
          });
        }
        if (uri.queryParameters['city'] == 'Santos') {
          return const JsonReply(200, {'items': []});
        }
        return const JsonReply(200, {'items': [], 'nextCursor': 'next'});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await openSearch(tester);
      await reveal(
        tester,
        find.text('Nenhuma corrida nesta página. Continue a busca.'),
      );
      expect(
        find.text('Nenhuma corrida nesta página. Continue a busca.'),
        findsOneWidget,
      );
      await reveal(tester, find.text('Carregar mais'));
      await tester.tap(find.text('Carregar mais'));
      await tester.pumpAndSettle();
      expect(find.text('Corrida B'), findsOneWidget);
      expect(calls.last['cursor'], 'next');
      await reveal(
        tester,
        find.widgetWithText(TextFormField, 'Cidade'),
        backwards: true,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Cidade'),
        'Santos',
      );
      await reveal(tester, find.text('Buscar'));
      await tester.tap(find.text('Buscar'));
      await tester.pumpAndSettle();
      expect(calls.last['city'], 'Santos');
      expect(calls.last.containsKey('cursor'), false);
      await reveal(
        tester,
        find.text('Nenhuma corrida encontrada com esses filtros.'),
      );
      expect(
        find.text('Nenhuma corrida encontrada com esses filtros.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('clear search empties filters and reloads without them', (
    tester,
  ) async {
    final calls = <Map<String, String>>[];
    final gateway = await signed((uri, method, headers, body) async {
      calls.add(uri.queryParameters);
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.text('Encontre sua próxima conquista'), findsNothing);
    await openSearch(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Cidade'),
      'Santos',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Estado (UF)'),
      'S',
    );
    await reveal(tester, find.text('Buscar'));
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    expect(find.text('Informe a UF.'), findsOneWidget);
    await reveal(tester, find.text('Limpar busca'));
    await tester.tap(find.text('Limpar busca'));
    await tester.pumpAndSettle();
    expect(find.text('Informe a UF.'), findsNothing);
    expect(calls.last.containsKey('city'), false);
    expect(calls.last.containsKey('state'), false);
    for (final label in ['Cidade', 'Estado (UF)']) {
      await reveal(
        tester,
        find.widgetWithText(TextFormField, label),
        backwards: true,
      );
      final field = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, label),
      );
      expect(field.controller!.text, '');
    }
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
      // O nome da corrida aparece só no banner (em maiúsculas), não repetido abaixo.
      expect(find.text('CORRIDA A'), findsOneWidget);
      expect(find.text('Corrida A'), findsNothing);
      await tester.tap(find.text('10K'));
      await tester.pumpAndSettle();
      expect(find.text('Distância selecionada.'), findsOneWidget);
      expect(paths.where((c) => c != '/me/participations'), [
        '/editions',
        '/editions/A',
        '/editions/A/reviews',
        '/editions/A/reviews',
      ]);
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
    await tester.tap(find.text('Criar rascunho'));
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
    await tester.tap(find.text('Criar rascunho'));
    await tester.pumpAndSettle();
    expect(find.text('Rascunho da participação'), findsOneWidget);
    expect(find.textContaining('não gera medalha'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Tempo (h:mm:ss ou segundos, opcional)'),
      '3600',
    );
    await tester.tap(find.text('Salvar rascunho'));
    await tester.pumpAndSettle();
    expect(find.text('Rascunho salvo. Nada foi publicado.'), findsOneWidget);
    expect(
      calls.where(
        (c) => !c.contains('/me/participations') && !c.endsWith('/image'),
      ),
      [
        'GET /editions/A',
        'GET /editions/A/reviews',
        'GET /editions/A/reviews',
        'POST /participations',
        'GET /editions/A',
        'PATCH /participations/draft-1',
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
      // Estrelas comecam vazias: sem notas, concluir fica desabilitado.
      expect(
        find.text(
          'Dê uma nota de 1 a 5 estrelas em todos os critérios para concluir.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Concluir participação'),
            )
            .onPressed,
        isNull,
      );
      await rateAll(tester, skip: 'Segurança');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Concluir participação'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('rating-Segurança-4')));
      await tester.pump();
      await tester.scrollUntilVisible(declaration, 200, scrollable: list);
      await tester.tap(declaration);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
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
          (c) => !c.contains('/me/participations') && !c.endsWith('/image'),
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

  testWidgets('protected catalog error does not show results', (tester) async {
    final gateway = await signed(
      (uri, method, headers, body) async =>
          const JsonReply(403, {'code': 'BETA_ADMISSION_REQUIRED'}),
    );
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await reveal(
      tester,
      find.text(
        'É necessário participar do período de avaliação para consultar as corridas.',
      ),
    );
    expect(
      find.text(
        'É necessário participar do período de avaliação para consultar as corridas.',
      ),
      findsOneWidget,
    );
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('completed participation edits review and can be deleted', (
    tester,
  ) async {
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
    await tester.scrollUntilVisible(
      find.text('Editar avaliação'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Editar avaliação'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Salvar avaliação'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byType(TextField), '');
    await tester.scrollUntilVisible(
      find.text('Salvar avaliação'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Salvar avaliação'));
    await tester.pumpAndSettle();
    expect(find.text('Avaliação atualizada.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Excluir participação'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Excluir participação').last);
    await tester.pumpAndSettle();
    // Depois de excluir volta para a lista de medalhas, com aviso.
    expect(find.byType(MedalCollectionScreen), findsOneWidget);
    expect(find.textContaining('Participação excluída'), findsOneWidget);
    // Depois do DELETE a lista de medalhas faz suas próprias consultas.
    expect(
      calls
          .sublist(0, calls.indexOf('DELETE /participations/done-1') + 1)
          .where((c) => !c.endsWith('/image')),
      [
        'GET /participations/done-1/review', // minha avaliação ao abrir
        'GET /participations/done-1/review', // tela de edição
        'PUT /participations/done-1/review',
        'GET /participations/done-1/review', // recarrega ao voltar
        'DELETE /participations/done-1',
      ],
    );
  });

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
      await tester.tap(find.byKey(const Key('rating-Kit-2')));
      await tester.pump();
      final declaration = find.text('Declaro que concluí esta corrida');
      await tester.scrollUntilVisible(declaration, 200, scrollable: list);
      await tester.tap(declaration);
      await tester.pump();
      final finish = find.text('Concluir participação');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
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
    await reveal(tester, find.textContaining('Já está na sua lista'));
    expect(find.textContaining('Já está na sua lista'), findsOneWidget);
    await tester.ensureVisible(find.text('Corrida A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Corrida A'));
    await tester.pumpAndSettle();
    // Tocar abre a página da corrida (informações e avaliações), não uma pergunta.
    expect(find.text('Corrida já cadastrada'), findsNothing);
    expect(find.byType(EditionScreen), findsOneWidget);
    expect(find.byKey(const Key('already-mine')), findsOneWidget);
    expect(find.text('Criar rascunho'), findsNothing);
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
      final timeLabel = find.text('Tempo (h:mm:ss ou segundos, opcional)');
      await tester.scrollUntilVisible(timeLabel, 200, scrollable: list);
      final timeField = find.widgetWithText(
        TextField,
        'Tempo (h:mm:ss ou segundos, opcional)',
      );
      expect(tester.widget<TextField>(timeField).controller!.text, '1:00:00');
      await tester.tap(find.byKey(const Key('distance-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5K').last);
      await tester.pumpAndSettle();
      await tester.enterText(timeField, '1:30:00');
      await tester.enterText(
        find.widgetWithText(TextField, 'Número de peito (opcional)'),
        '4821',
      );
      await tester.scrollUntilVisible(
        find.text('Salvar dados da corrida'),
        200,
        scrollable: list,
      );
      await tester.tap(find.text('Salvar dados da corrida'));
      await tester.pumpAndSettle();
      expect(patched?['expectedVersion'], 3);
      expect(patched?['distanceId'], '5k');
      expect(patched?['timeSeconds'], 5400);
      expect(patched?['bibNumber'], '4821');
      expect(find.text('Dados da corrida salvos.'), findsOneWidget);
    },
  );

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
    expect(find.text('Minha avaliação'), findsOneWidget);
    expect(find.text('“Percurso bonito”'), findsOneWidget);
    expect(find.text('Hidratação'), findsOneWidget);
  });

  testWidgets(
    'filtro de inscricoes envia registrationStatus e some ao limpar',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <Map<String, String>>[];
      final gateway = await signed((uri, method, headers, body) async {
        calls.add(uri.queryParameters);
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await openSearch(tester);
      await tester.tap(find.byKey(const ValueKey('filter-registration-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abertas').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Buscar'));
      await tester.tap(find.text('Buscar'));
      await tester.pumpAndSettle();
      expect(calls.last['registrationStatus'], 'open');
      await tester.ensureVisible(find.text('Limpar busca'));
      await tester.tap(find.text('Limpar busca'));
      await tester.pumpAndSettle();
      expect(calls.last.containsKey('registrationStatus'), isFalse);
    },
  );

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

  group('busca por frase livre', () {
    Future<void> typePhrase(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const Key('catalog-phrase')), text);
      await tester.ensureVisible(find.text('Buscar'));
      await tester.tap(find.text('Buscar'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'usa /editions/search, lista o resultado e pagina por /editions com os filtros do servidor',
      (tester) async {
        tester.view.physicalSize = const Size(800, 3000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final calls = <Uri>[];
        final gateway = await signed((uri, method, headers, body) async {
          calls.add(uri);
          if (uri.path == '/editions/search') {
            return JsonReply(200, {
              'items': [entry('S1')],
              'nextCursor': 'c1',
              'search': {
                'source': 'llm',
                'filters': {'state': 'SP', 'distanceKm': '21.1'},
                'applied': ['uf', 'distancia_km'],
                'notApplied': <String>[],
              },
            });
          }
          if (uri.path == '/editions' &&
              uri.queryParameters['cursor'] == 'c1') {
            return JsonReply(200, {
              'items': [entry('S2')],
            });
          }
          return const JsonReply(200, {'items': []});
        });
        await tester.pumpWidget(
          MaterialApp(home: CatalogScreen(gateway: gateway)),
        );
        await tester.pumpAndSettle();
        await openSearch(tester);
        await typePhrase(tester, '  meia maratona em SP  ');
        final search = calls.lastWhere((u) => u.path == '/editions/search');
        expect(search.queryParameters, {
          'phrase': 'meia maratona em SP',
          'limit': '20',
        });
        expect(find.text('Corrida S1'), findsOneWidget);
        expect(find.byKey(const Key('catalog-search-notice')), findsNothing);
        await reveal(tester, find.text('Carregar mais'));
        await tester.tap(find.text('Carregar mais'));
        await tester.pumpAndSettle();
        expect(calls.last.path, '/editions');
        expect(calls.last.queryParameters, {
          'state': 'SP',
          'distanceKm': '21.1',
          'limit': '20',
          'cursor': 'c1',
        });
        expect(find.text('Corrida S2'), findsOneWidget);
      },
    );

    testWidgets('avisa o que nao foi filtrado e quando a IA nao respondeu', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var source = 'llm';
      final gateway = await signed((uri, method, headers, body) async {
        if (uri.path == '/editions/search') {
          return JsonReply(200, {
            'items': [entry('S1')],
            'search': {
              'source': source,
              'filters': {'q': 'x'},
              'applied': ['texto'],
              'notApplied': ['preco_max_brl', 'altimetria'],
            },
          });
        }
        return const JsonReply(200, {'items': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await openSearch(tester);
      await typePhrase(tester, 'corrida barata e plana');
      var notice = tester.widget<Text>(
        find.byKey(const Key('catalog-search-notice')),
      );
      expect(notice.data, contains('Não filtrei por: preço, altimetria.'));
      expect(notice.data, isNot(contains('interpretar a frase')));
      source = 'text';
      await typePhrase(tester, 'corrida barata e plana 2');
      notice = tester.widget<Text>(
        find.byKey(const Key('catalog-search-notice')),
      );
      expect(
        notice.data,
        contains('Não foi possível interpretar a frase agora'),
      );
    });

    testWidgets('sem frase usa os campos de sempre, e limpar volta a lista', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <Uri>[];
      final gateway = await signed((uri, method, headers, body) async {
        calls.add(uri);
        return JsonReply(200, {
          'items': [entry('S1')],
          if (uri.path == '/editions/search')
            'search': {
              'source': 'llm',
              'filters': <String, dynamic>{},
              'applied': <String>[],
              'notApplied': ['consulta_semantica'],
            },
        });
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await openSearch(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Cidade'),
        'Sao Paulo',
      );
      await tester.ensureVisible(find.text('Buscar'));
      await tester.tap(find.text('Buscar'));
      await tester.pumpAndSettle();
      expect(calls.last.path, '/editions');
      expect(calls.last.queryParameters['city'], 'Sao Paulo');
      await typePhrase(tester, 'qualquer coisa');
      expect(calls.last.path, '/editions/search');
      expect(find.byKey(const Key('catalog-search-notice')), findsOneWidget);
      await tester.ensureVisible(find.text('Limpar busca'));
      await tester.tap(find.text('Limpar busca'));
      await tester.pumpAndSettle();
      expect(calls.last.path, '/editions');
      expect(calls.last.queryParameters.containsKey('phrase'), isFalse);
      expect(find.byKey(const Key('catalog-search-notice')), findsNothing);
    });
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
        '2027-03-14',
      );
      await tester.enterText(
        find.byKey(const Key('request-distanceKm')),
        '10,5',
      );
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
        // O pedido fica junto da pesquisa, na lupa: fechada, nao aparece no fim da lista.
        expect(find.byKey(const Key('catalog-request-new')), findsNothing);
        await openSearch(tester);
        await reveal(tester, find.byKey(const Key('catalog-request-new')));
        await tester.tap(find.byKey(const Key('catalog-request-new')));
        await tester.pumpAndSettle();
        expect(find.text('Pedir cadastro da corrida'), findsWidgets);
        await fillRequest(tester);
        await tester.tap(find.byKey(const Key('request-submit')));
        await tester.pumpAndSettle();
        expect(posts.single, {
          'name': 'Night Run',
          'date': '2027-03-14',
          'city': 'São Paulo',
          'state': 'SP',
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
        '14/03/2027',
      );
      await tester.enterText(find.byKey(const Key('request-distanceKm')), '-3');
      await tester.enterText(
        find.byKey(const Key('request-officialUrl')),
        'http://x.org',
      );
      await tester.tap(find.byKey(const Key('request-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('Use uma data válida no formato AAAA-MM-DD.'),
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
          '2027-03-21',
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
    'o campo de frase aparece sem abrir os filtros e busca pelo teclado',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <Uri>[];
      final gateway = await signed((uri, method, headers, body) async {
        calls.add(uri);
        return JsonReply(200, {
          'items': [entry('S1')],
          if (uri.path == '/editions/search')
            'search': {
              'source': 'llm',
              'filters': {'q': 'night'},
              'applied': ['texto'],
              'notApplied': <String>[],
            },
        });
      });
      await tester.pumpWidget(
        MaterialApp(home: CatalogScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      // Sem tocar na lupa: o campo ja esta na tela, com o rotulo certo.
      expect(find.byKey(const Key('catalog-phrase')), findsOneWidget);
      expect(find.text('Descreva a corrida'), findsOneWidget);
      expect(
        find.text('Encontre sua próxima conquista'),
        findsNothing,
      ); // cartão de filtros fechado
      await tester.enterText(
        find.byKey(const Key('catalog-phrase')),
        'night run',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(calls.last.path, '/editions/search');
      expect(calls.last.queryParameters['phrase'], 'night run');
      // O botao de limpar volta a lista completa.
      await tester.tap(find.byKey(const Key('catalog-phrase-clear')));
      await tester.pumpAndSettle();
      expect(calls.last.path, '/editions');
      expect(find.byKey(const Key('catalog-phrase-clear')), findsNothing);
    },
  );

  testWidgets('sem resultado, a tela oferece pedir o cadastro direto', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = await signed((uri, method, headers, body) async {
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(
      find.text('Nenhuma corrida encontrada com esses filtros.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('catalog-request-empty')));
    await tester.pumpAndSettle();
    expect(find.text('Pedir cadastro da corrida'), findsWidgets);
    expect(find.byKey(const Key('request-submit')), findsOneWidget);
  });

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
    expect(find.byKey(const Key('catalog-request-new')), findsNothing);
  });

  testWidgets('ordenar a lista por data e por nota (ranking das melhores)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Map<String, dynamic> race(String id, String date, {double? score}) => {
      ...entry(id),
      'id': 'E$id',
      'date': date,
      if (score != null) 'runScore': {'value': score, 'reviewCount': 12},
    };
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/editions') {
        return JsonReply(200, {
          'items': [
            race('A', '2024-05-01', score: 4.2),
            race('B', '2025-05-01'),
            race('C', '2026-05-01', score: 4.8),
          ],
        });
      }
      return const JsonReply(200, {'items': []});
    });
    await tester.pumpWidget(MaterialApp(home: CatalogScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    double top(String text) => tester.getTopLeft(find.textContaining(text)).dy;
    expect(top('Corrida A') < top('Corrida B'), isTrue); // padrão: do servidor
    Future<void> choose(String label) async {
      await tester.tap(find.byKey(const Key('catalog-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await choose('Data: mais recentes primeiro');
    expect(top('Corrida C') < top('Corrida B'), isTrue);
    expect(top('Corrida B') < top('Corrida A'), isTrue);
    await choose('Melhores avaliadas (ranking)');
    expect(find.textContaining('#1 · Corrida C'), findsOneWidget);
    expect(find.textContaining('#2 · Corrida A'), findsOneWidget);
    expect(
      find.textContaining('#3'),
      findsNothing,
    ); // sem nota: fim, sem posição
    expect(top('Corrida A') < top('Corrida B'), isTrue);
    expect(find.textContaining('★ 4,8 · 12 avaliações'), findsOneWidget);
  });
}
