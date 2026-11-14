import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/edition_requests.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/medal_scan.dart';

final onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Map<String, dynamic> edition(
  String id,
  String name,
  String date,
  String city,
  String state,
  num km,
) => {
  'id': id,
  'name': name,
  'date': date,
  'city': city,
  'state': state,
  'status': 'past',
  'version': 1,
  'distances': [
    {'id': 'd', 'kilometers': km},
  ],
};

Map<String, dynamic> done(
  String id,
  String editionId, {
  int? seconds,
  bool published = false,
  String? completedAt,
}) => {
  'id': id,
  'editionId': editionId,
  'distanceId': 'd',
  'state': 'completed',
  'version': 2,
  'timeSeconds': ?seconds,
  if (seconds != null) 'paceSecondsPerKm': seconds ~/ 5,
  'publishToFeed': published,
  'completedAt': ?completedAt,
};

Future<IdentityGateway> runner({
  bool noRaces = false,
  List<Map<String, dynamic>> found = const [],
}) async {
  final editions = {
    'a': edition('a', 'Corrida A', '2026-09-01', 'São Paulo', 'SP', 5),
    'b': edition('b', 'Corrida B', '2025-05-01', 'Rio de Janeiro', 'RJ', 10),
  };
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
          'displayName': 'Corredor Teste',
          'username': 'teste',
          'city': 'Santos',
          'version': 1,
        });
      }
      if (uri.path == '/me/participations') {
        return JsonReply(200, {
          'items': noRaces
              ? []
              : [
                  done('p1', 'a', seconds: 1500),
                  done('p2', 'b'),
                  {...done('p3', 'a'), 'state': 'draft'},
                ],
        });
      }
      if (uri.path == '/editions') return JsonReply(200, {'items': found});
      final match = editions[uri.pathSegments.last];
      return match == null
          ? const JsonReply(404, {'code': 'EDITION_NOT_FOUND'})
          : JsonReply(200, match);
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return gateway;
}

void main() {
  testWidgets(
    'Medalhas troca Conquistas por Por cidade, agrupando por cidade visitada',
    (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: MedalCollectionScreen(gateway: await runner())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Conquistas'), findsNothing);
      expect(find.text('Minhas medalhas'), findsOneWidget);
      await tester.tap(find.text('Por cidade'));
      await tester.pumpAndSettle();
      expect(find.text('Rio de Janeiro/RJ'), findsOneWidget);
      expect(find.text('São Paulo/SP'), findsOneWidget);
      // Ordem alfabética: Rio antes de São Paulo; cada medalha no grupo da sua cidade.
      expect(
        tester.getTopLeft(find.text('Rio de Janeiro/RJ')).dy,
        lessThan(tester.getTopLeft(find.text('São Paulo/SP')).dy),
      );
      expect(find.text('Corrida A'), findsOneWidget);
      expect(find.text('Corrida B'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Corrida B')).dy,
        lessThan(tester.getTopLeft(find.text('Corrida A')).dy),
      );
    },
  );

  testWidgets(
    'medal collection shows counts and regroups by year and distance',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: MedalCollectionScreen(gateway: await runner())),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
      expect(find.text('Corrida A'), findsOneWidget);
      expect(find.text('Corrida B'), findsOneWidget);
      // Two completed races (5km + 10km) in two cities; the draft is not a medal.
      expect(find.text("km's\npercorridos"), findsOneWidget);
      expect(find.text('medalhas\nconquistadas'), findsOneWidget);
      expect(find.text('cidades\nvisitadas'), findsOneWidget);
      expect(find.text('15'), findsOneWidget);
      // Medalhas e cidades valem 2.
      expect(find.text('2'), findsNWidgets(2));
      await tester.tap(find.text('Por ano'));
      await tester.pumpAndSettle();
      expect(find.text('2026'), findsOneWidget);
      final medalsList = find
          .descendant(
            of: find.byKey(const Key('medals-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('2025'),
        200,
        scrollable: medalsList,
      );
      expect(find.text('2025'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Por distância'),
        -2000,
        scrollable: medalsList,
      );
      await tester.tap(find.text('Por distância'));
      await tester.pumpAndSettle();
      expect(find.text('5K'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('10K'),
        200,
        scrollable: medalsList,
      );
      expect(find.text('10K'), findsOneWidget);
    },
  );

  testWidgets('tocar na aba Perfil (foto do usuário) abre o Perfil', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: MedalCollectionScreen(gateway: await runner())),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RunnerProfileScreen), findsNothing);
    expect(find.byKey(const Key('nav-profile-avatar')), findsOneWidget);
    await tester.tap(find.text('Perfil'));
    await tester.pumpAndSettle();
    expect(find.byType(RunnerProfileScreen), findsOneWidget);
    expect(find.byType(MedalCollectionScreen), findsNothing);
  });

  Future<void> tapAdd(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('medal-add-tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('medal-add-tile')));
    await tester.pumpAndSettle();
  }

  testWidgets('"+" da prateleira pede a foto da medalha antes das corridas, '
      'lê o texto e lista as corridas achadas', (tester) async {
    final searched = <String>[];
    final gateway = await runner(
      found: [
        {
          'id': 'a',
          'name': 'Corrida A',
          'date': '2026-09-01',
          'city': 'São Paulo',
          'state': 'SP',
        },
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MedalCollectionScreen(
          gateway: gateway,
          medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
          medalTextReader: _FakeReader([
            'CIRCUITO DAS ESTAÇÕES',
            '10 KM',
            'PRIMAVERA 2026',
          ], onRead: searched.add),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapAdd(tester);
    expect(
      find.byType(CatalogScreen),
      findsNothing,
    ); // não vai direto às corridas
    expect(find.text('Adicionar medalha'), findsOneWidget);
    expect(find.byKey(const Key('medal-scan-found')), findsOneWidget);
    expect(find.byKey(const Key('medal-match-a')), findsOneWidget);
    expect(searched, ['/tmp/medalha.jpg']);
  });

  testWidgets(
    'sem corrida achada pela foto, o botão leva ao cadastro de corridas',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: await runner(),
            medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
            medalTextReader: _FakeReader(['CIRCUITO DAS ESTAÇÕES']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapAdd(tester);
      expect(find.byKey(const Key('medal-scan-note')), findsOneWidget);
      expect(find.byKey(const Key('medal-match-a')), findsNothing);
      await tester.tap(find.byKey(const Key('medal-scan-catalog')));
      await tester.pumpAndSettle();
      expect(find.byType(CatalogScreen), findsOneWidget);
    },
  );

  testWidgets(
    'sem corrida achada, dá para pedir o cadastro com o nome da medalha',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: await runner(),
            medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
            medalTextReader: _FakeReader([
              'CIRCUITO DAS ESTAÇÕES',
              '10 KM',
              '22/11/2026',
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapAdd(tester);
      expect(find.byKey(const Key('medal-scan-suggest')), findsOneWidget);
      expect(find.text('• Distância: 10 km'), findsOneWidget);
      expect(find.text('• Data: 22/11/2026'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('medal-scan-request')));
      await tester.tap(find.byKey(const Key('medal-scan-request')));
      await tester.pumpAndSettle();
      expect(find.byType(EditionRequestFormScreen), findsOneWidget);
      expect(find.text('CIRCUITO DAS ESTAÇÕES'), findsOneWidget);
    },
  );

  testWidgets('aparelho sem leitor de texto avisa e ainda leva às corridas', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MedalCollectionScreen(
          gateway: await runner(),
          medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
          medalTextReader: _FakeReader(const [], unavailable: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapAdd(tester);
    expect(find.textContaining('ainda não lê o texto'), findsOneWidget);
    expect(find.byKey(const Key('medal-scan-catalog')), findsOneWidget);
  });

  testWidgets('desistir da foto no "+" não abre nada', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MedalCollectionScreen(
          gateway: await runner(),
          medalPhotoPicker: (_) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapAdd(tester);
    expect(find.byType(MedalScanScreen), findsNothing);
    expect(find.byType(CatalogScreen), findsNothing);
    expect(find.byType(MedalCollectionScreen), findsOneWidget);
  });

  test(
    'medalQueries ignora números e ruído e põe o nome mais longo primeiro',
    () {
      expect(
        medalQueries([
          '10 KM',
          '2026',
          'FINISHER',
          'Circuito das Estações',
          'Primavera',
        ]),
        ['Circuito das Estações', 'Primavera'],
      );
      expect(medalQueries(const []), isEmpty);
      expect(medalQueries(['Ab', '12']), isEmpty);
    },
  );

  testWidgets(
    'excluir medalha: confirma, envia DELETE com a versão e some da lista',
    (tester) async {
      final calls = <String>[];
      var deleted = false;
      final editions = {
        'a': edition('a', 'Corrida A', '2026-09-01', 'São Paulo', 'SP', 5),
      };
      final gateway = IdentityGateway(
        cognito: Uri.parse('https://cognito.example'),
        api: Uri.parse('https://api.example'),
        clientId: 'synthetic',
        transport: (uri, method, headers, body) async {
          calls.add(
            '$method ${uri.path}${uri.query.isEmpty ? '' : '?${uri.query}'}',
          );
          if (uri.host == 'cognito.example') {
            return const JsonReply(200, {
              'AuthenticationResult': {'AccessToken': 'synthetic'},
            });
          }
          if (uri.path == '/me') {
            return const JsonReply(200, {
              'displayName': 'Corredor Teste',
              'username': 'teste',
              'version': 1,
            });
          }
          if (uri.path == '/me/participations') {
            return JsonReply(200, {
              'items': deleted ? [] : [done('p1', 'a', seconds: 1500)],
            });
          }
          if (uri.path == '/participations/p1' && method == 'DELETE') {
            deleted = true;
            return const JsonReply(200, {});
          }
          final match = editions[uri.pathSegments.last];
          return match == null
              ? const JsonReply(404, {'code': 'EDITION_NOT_FOUND'})
              : JsonReply(200, match);
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(home: MedalCollectionScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('medal-edit-p1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('medal-edit-p1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('medal-delete')));
      await tester.tap(find.byKey(const Key('medal-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Excluir medalha?'), findsOneWidget);
      // Cancelar não exclui nada.
      await tester.tap(find.text('Cancelar').last);
      await tester.pumpAndSettle();
      expect(calls.any((c) => c.startsWith('DELETE')), isFalse);

      await tester.tap(find.byKey(const Key('medal-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('medal-delete-confirm')));
      await tester.pumpAndSettle();
      expect(
        calls
            .where(
              (c) => c.startsWith('DELETE /participations/p1?expectedVersion='),
            )
            .length,
        1,
      );
      expect(find.byKey(const Key('medal-edit-p1')), findsNothing);
      expect(find.textContaining('saiu de Minhas corridas'), findsOneWidget);
    },
  );

  testWidgets(
    'seta de voltar só existe nas corridas abertas pelo "+", não nas abas',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: await runner(),
            medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
            medalTextReader: _FakeReader(const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsNothing);
      await tapAdd(tester);
      await tester.tap(find.byKey(const Key('medal-scan-catalog')));
      await tester.pumpAndSettle();
      expect(find.byType(CatalogScreen), findsOneWidget);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(navigator.canPop(), isTrue); // dá para voltar às medalhas
      await tester.tap(find.text('Perfil'));
      await tester.pumpAndSettle();
      expect(find.byType(RunnerProfileScreen), findsOneWidget);
      expect(navigator.canPop(), isFalse); // aba aberta: sem seta, sem pilha
      await tester.tap(find.text('Medalhas'));
      await tester.pumpAndSettle();
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
      expect(navigator.canPop(), isFalse);
    },
  );

  testWidgets('editar medalha: muda forma, cor e legenda e salva via PATCH', (
    tester,
  ) async {
    final calls = <String>[];
    var patchBody = <String, dynamic>{};
    final editions = {
      'a': edition('a', 'Corrida A', '2026-09-01', 'São Paulo', 'SP', 5),
    };
    final gateway = IdentityGateway(
      cognito: Uri.parse('https://cognito.example'),
      api: Uri.parse('https://api.example'),
      clientId: 'synthetic',
      transport: (uri, method, headers, body) async {
        calls.add('$method ${uri.path}');
        if (uri.host == 'cognito.example') {
          return const JsonReply(200, {
            'AuthenticationResult': {'AccessToken': 'synthetic'},
          });
        }
        if (uri.path == '/me') {
          return const JsonReply(200, {
            'displayName': 'Corredor Teste',
            'username': 'teste',
            'version': 1,
          });
        }
        if (uri.path == '/me/participations') {
          return JsonReply(200, {
            'items': [done('p1', 'a', seconds: 1500)],
          });
        }
        if (uri.path == '/participations/p1' && method == 'PATCH') {
          patchBody = Map<String, dynamic>.from(body as Map);
          return const JsonReply(200, {'id': 'p1'});
        }
        final match = editions[uri.pathSegments.last];
        return match == null
            ? const JsonReply(404, {'code': 'EDITION_NOT_FOUND'})
            : JsonReply(200, match);
      },
    );
    await gateway.signIn('synthetic@example.test', 'synthetic');

    await tester.pumpWidget(
      MaterialApp(home: MedalCollectionScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('medal-edit-p1')));
    await tester.pumpAndSettle();
    expect(find.text('Personalizar medalha'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('medal-frame-hexagonal_bronze_verde')),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Nome da Corrida'),
      '',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Nome da Corrida'),
      'Minha prova especial',
    );
    await tester.tap(find.byKey(const Key('medal-edit-save')));
    await tester.pumpAndSettle();

    expect(patchBody['expectedVersion'], 2);
    expect(patchBody['medalFrameId'], 'hexagonal_bronze_verde');
    expect(patchBody['medalDescription'], 'Minha prova especial');
    // Cidade, UF e ano nao sao mais editaveis aqui: sempre voltam ao
    // catalogo da corrida.
    expect(patchBody['medalCity'], null);
    expect(patchBody['medalState'], null);
    expect(patchBody['medalYear'], null);
    expect(calls.where((c) => c == 'PATCH /participations/p1').length, 1);
    expect(find.text('Personalizar medalha'), findsNothing);
  });

  testWidgets(
    'reposicionar foto da medalha: recorta, envia e inclui no PATCH',
    (tester) async {
      final calls = <String>[];
      var patchBody = <String, dynamic>{};
      final editions = {
        'a': edition('a', 'Corrida A', '2026-09-01', 'São Paulo', 'SP', 5),
      };
      final gateway = IdentityGateway(
        cognito: Uri.parse('https://cognito.example'),
        api: Uri.parse('https://api.example'),
        clientId: 'synthetic',
        byteTransport: (uri, method, headers, bytes) async => 200,
        transport: (uri, method, headers, body) async {
          calls.add('$method ${uri.path}');
          if (uri.host == 'cognito.example') {
            return const JsonReply(200, {
              'AuthenticationResult': {'AccessToken': 'synthetic'},
            });
          }
          if (uri.path == '/me') {
            return const JsonReply(200, {
              'displayName': 'Corredor Teste',
              'username': 'teste',
              'version': 1,
            });
          }
          if (uri.path == '/me/participations') {
            return JsonReply(200, {
              'items': [done('p1', 'a', seconds: 1500)],
            });
          }
          if (uri.path == '/participations/p1/image') {
            return const JsonReply(200, {
              'url': 'https://signed.example/current.jpg',
              'contentType': 'image/png',
              'expiresAt': '2026-01-01T00:00:00Z',
            });
          }
          if (uri.path == '/uploads') {
            return const JsonReply(201, {
              'uploadId': 'up1',
              'uploadUrl': 'https://signed.example/up1',
              'uploadMethod': 'PUT',
              'uploadHeaders': {'Content-Type': 'image/png'},
            });
          }
          if (uri.path == '/uploads/up1/finalize') {
            return const JsonReply(200, {
              'uploadId': 'up1',
              'state': 'valid',
              'imageReference': 'img-cropped',
            });
          }
          if (uri.path == '/participations/p1' && method == 'PATCH') {
            patchBody = Map<String, dynamic>.from(body as Map);
            return const JsonReply(200, {'id': 'p1'});
          }
          final match = editions[uri.pathSegments.last];
          return match == null
              ? const JsonReply(404, {'code': 'EDITION_NOT_FOUND'})
              : JsonReply(200, match);
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');

      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            fetchDisplayPhoto: (url) async => onePixelPng,
            openCropScreen: (context, image, frame) async => image,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('medal-edit-p1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('medal-reposition-photo')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('medal-reset-photo')), findsOneWidget);

      await tester.tap(find.byKey(const Key('medal-edit-save')));
      await tester.pumpAndSettle();

      expect(patchBody['medalDisplayImageReference'], 'img-cropped');
      expect(calls, contains('GET /participations/p1/image'));
      expect(calls, contains('POST /uploads/up1/finalize'));
    },
  );

  testWidgets(
    'medal collection without completed races keeps the empty state',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(gateway: await runner(noRaces: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Você ainda não concluiu uma corrida. Sua primeira medalha aparecerá aqui.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('home highlights the latest conquest with time and pace', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: RunPassHomeScreen(gateway: await runner())),
    );
    await tester.pumpAndSettle();
    expect(find.text('concluiu Corrida A'), findsOneWidget);
    expect(find.text('5 km'), findsOneWidget);
    expect(find.text('25:00'), findsOneWidget);
    expect(find.text('5:00/km'), findsOneWidget);
  });

  testWidgets('profile summarizes completed races by distance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: RunnerProfileScreen(gateway: await runner())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Corredor Teste'), findsOneWidget);
    expect(find.text('@teste  •  Santos'), findsOneWidget);
    expect(find.byKey(const Key('profile-counts')), findsOneWidget);
    expect(find.text('seguidores'), findsOneWidget);
    expect(find.text('seguindo'), findsOneWidget);
    expect(find.text('provas\nconcluídas'), findsOneWidget);
    expect(find.text('corridas\n5K'), findsOneWidget);
    expect(find.text('corridas\n10K'), findsOneWidget);
    // Nenhuma das corridas de teste foi publicada no feed: secao vazia.
    expect(find.byKey(const Key('no-my-posts')), findsOneWidget);
  });

  testWidgets(
    'minhas publicações: só corridas publicadas, como cartões do Feed, mais recente primeiro',
    (tester) async {
      tester.view.physicalSize = const Size(1179, 4000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final paths = <String>[];
      final editions = {
        'a': edition('a', 'Corrida A', '2026-09-01', 'São Paulo', 'SP', 5),
        'b': edition(
          'b',
          'Corrida B',
          '2025-05-01',
          'Rio de Janeiro',
          'RJ',
          10,
        ),
      };
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
          paths.add(uri.path);
          if (uri.path == '/me') {
            return const JsonReply(200, {
              'id': 'eu',
              'displayName': 'Corredor Teste',
              'username': 'teste',
              'version': 1,
            });
          }
          if (uri.path == '/me/participations') {
            return JsonReply(200, {
              'items': [
                done(
                  'p1',
                  'a',
                  published: true,
                  completedAt: '2026-09-02T10:00:00Z',
                ),
                done(
                  'p2',
                  'b',
                  published: true,
                  completedAt: '2025-05-02T10:00:00Z',
                ),
                done('p3', 'a'), // nao publicada: fica de fora da secao
              ],
            });
          }
          final post = {
            'p1': ('a', '2026-09-02T10:00:00Z'),
            'p2': ('b', '2025-05-02T10:00:00Z'),
          }[uri.pathSegments.last];
          if (uri.path.startsWith('/posts/') && post != null) {
            final (editionId, publishedAt) = post;
            return JsonReply(200, {
              'id': uri.pathSegments.last,
              'author': {
                'id': 'eu',
                'displayName': 'Corredor Teste',
                'username': 'teste',
                'version': 1,
              },
              'participation': {
                'id': uri.pathSegments.last,
                'editionId': editionId,
                'distanceId': 'd',
                'state': 'completed',
              },
              'publishedAt': publishedAt,
              'commentCount': 0,
              'likeCount': 0,
              'likedByMe': false,
            });
          }
          final match = editions[uri.pathSegments.last];
          return match == null
              ? const JsonReply(404, {'code': 'EDITION_NOT_FOUND'})
              : JsonReply(200, match);
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no-my-posts')), findsNothing);
      // Miniaturas em grade, 3 por linha.
      expect(find.byKey(const Key('my-post-p1')), findsOneWidget);
      expect(find.byKey(const Key('my-post-p2')), findsOneWidget);
      expect(find.byKey(const Key('my-post-p3')), findsNothing);
      expect(paths, containsAll(['/posts/p1', '/posts/p2']));
      // Mais recente primeiro: p1 (set/2026) antes de p2 (mai/2025), na mesma linha.
      final p1 = tester.getTopLeft(find.byKey(const Key('my-post-p1')));
      final p2 = tester.getTopLeft(find.byKey(const Key('my-post-p2')));
      expect(p1.dy, p2.dy);
      expect(p1.dx, lessThan(p2.dx));
      final grid = tester.getSize(find.byKey(const Key('my-posts-grid')));
      final tile = tester.getSize(find.byKey(const Key('my-post-p1')));
      expect(tile.width, lessThan(grid.width / 3));
      expect(tile.width, greaterThan(grid.width / 3 - 12));
      expect(find.text('Corrida A'), findsOneWidget);
      expect(find.text('Corrida B'), findsOneWidget);
      // Tocar abre a publicacao inteira.
      await tester.ensureVisible(find.byKey(const Key('my-post-p1')));
      await tester.tap(find.byKey(const Key('my-post-p1')));
      await tester.pumpAndSettle();
      expect(find.text('Publicação'), findsOneWidget);
      expect(find.text('concluiu Corrida A'), findsOneWidget);
    },
  );
}

class _FakeReader implements MedalTextReader {
  final List<String> lines;
  final bool unavailable;
  final void Function(String path)? onRead;
  _FakeReader(this.lines, {this.unavailable = false, this.onRead});

  @override
  Future<List<String>> read(String path) async {
    onRead?.call(path);
    if (unavailable) throw MedalReadUnavailable();
    return lines;
  }
}
