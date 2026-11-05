import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
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
      expect(find.text('Corrida A'), findsOneWidget);
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
      find.widgetWithText(TextField, 'Tempo em segundos (opcional)'),
      '3600',
    );
    await tester.tap(find.text('Salvar rascunho'));
    await tester.pumpAndSettle();
    expect(find.text('Rascunho salvo. Nada foi publicado.'), findsOneWidget);
    expect(calls.where((c) => !c.contains('/me/participations')), [
      'GET /editions/A',
      'GET /editions/A/reviews',
      'GET /editions/A/reviews',
      'POST /participations',
      'GET /editions/A',
      'PATCH /participations/draft-1',
    ]);
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
      await tester.scrollUntilVisible(declaration, 200, scrollable: list);
      await tester.tap(declaration);
      await tester.pumpAndSettle();
      final finish = find.text('Concluir participação');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      await tester.tap(finish);
      await tester.pumpAndSettle();

      expect(completion?['declaredCompleted'], true);
      expect((completion?['ratings'] as Map).length, 8);
      expect(completion?['medalImageReference'], 'img-valid');
      expect(find.textContaining('Participação concluída'), findsWidgets);
      expect(find.text('Salvar rascunho'), findsNothing);
      expect(find.text('Selecionar foto'), findsNothing);
      expect(find.textContaining('Privado · não gera medalha'), findsNothing);
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
      expect(calls.where((c) => !c.contains('/me/participations')), [
        'GET /editions/A',
        'POST /uploads',
        'PUT signed-object',
        'POST /uploads/upload-1/finalize',
        'POST /participations/draft-1/complete',
      ]);
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
      find.text('É necessário participar do beta para consultar as corridas.'),
    );
    expect(
      find.text('É necessário participar do beta para consultar as corridas.'),
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
    expect(find.textContaining('A participação foi ocultada'), findsOneWidget);
    expect(calls, [
      'GET /participations/done-1/review',
      'PUT /participations/done-1/review',
      'DELETE /participations/done-1',
    ]);
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
    'a race that has not happened yet explains and blocks completion',
    (tester) async {
      var completed = false;
      final gateway = await draftGateway('2999-01-01', (_) => completed = true);
      await openDraftWithPhoto(tester, gateway);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('upcoming-notice')),
        200,
        scrollable: list,
      );
      expect(find.textContaining('Esta corrida acontece em'), findsOneWidget);
      final finish = find.widgetWithText(FilledButton, 'Concluir participação');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      expect(tester.widget<FilledButton>(finish).onPressed, isNull);
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
    await tester.tap(find.text('Corrida A'));
    await tester.pumpAndSettle();
    expect(find.text('Corrida já cadastrada'), findsOneWidget);
    expect(find.textContaining('já está na sua timeline'), findsOneWidget);
    // "Não" volta para a lista sem abrir nada.
    await tester.tap(find.text('Não'));
    await tester.pumpAndSettle();
    expect(find.text('Rascunho da participação'), findsNothing);
    expect(find.byType(CatalogScreen), findsOneWidget);
    // "Sim" abre a edição do registro existente.
    await tester.tap(find.text('Corrida A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sim'));
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
}
