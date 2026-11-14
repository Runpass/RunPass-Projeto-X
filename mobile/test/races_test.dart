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
  List<Map<String, dynamic>> requests = const [],
  bool Function(String q)? foundFor,
  bool participationExists = false,
}) async {
  final editions = {
    'a': edition('a', 'Corrida A', '2026-09-01', 'São Paulo', 'SP', 5),
    'b': edition('b', 'Corrida B', '2025-05-01', 'Rio de Janeiro', 'RJ', 10),
  };
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
      if (uri.path == '/editions') {
        final show = foundFor?.call(uri.queryParameters['q'] ?? '') ?? true;
        return JsonReply(200, {'items': show ? found : []});
      }
      if (uri.path == '/uploads' && method == 'POST') {
        return const JsonReply(201, {
          'uploadId': 'up1',
          'uploadUrl': 'https://signed.example/up1',
          'uploadMethod': 'PUT',
          'uploadHeaders': {'Content-Type': 'image/jpeg'},
        });
      }
      if (uri.path == '/uploads/up1/finalize') {
        return const JsonReply(200, {
          'uploadId': 'up1',
          'state': 'valid',
          'imageReference': 'img_ok',
        });
      }
      if (uri.path == '/participations/d1/complete') {
        return const JsonReply(200, {
          'id': 'd1',
          'editionId': 'a',
          'distanceId': '10k',
          'state': 'completed',
          'version': 2,
          'medalImageReference': 'img_ok',
        });
      }
      if (uri.path == '/participations' && method == 'POST') {
        if (participationExists) {
          return const JsonReply(409, {'code': 'PARTICIPATION_EXISTS'});
        }
        final sent = body! as Map;
        return JsonReply(201, {
          'id': 'd1',
          'editionId': sent['editionId'],
          'distanceId': sent['distanceId'],
          'state': 'draft',
          'version': 1,
        });
      }
      if (uri.path == '/me/edition-requests') {
        return JsonReply(200, {'items': requests});
      }
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
    // Tela alta: a tela da foto agora tem os campos editáveis acima dos botões.
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('medal-edit-distance')))
            .controller!
            .text,
        '10',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('medal-edit-date')))
            .controller!
            .text,
        '22/11/2026',
      );
      await tester.ensureVisible(find.byKey(const Key('medal-scan-request')));
      await tester.tap(find.byKey(const Key('medal-scan-request')));
      await tester.pumpAndSettle();
      expect(find.byType(EditionRequestFormScreen), findsOneWidget);
      expect(find.text('CIRCUITO DAS ESTAÇÕES'), findsOneWidget);
    },
  );

  testWidgets(
    'dá para corrigir o que foi lido, buscar de novo e concluir com os dados editados',
    (tester) async {
      final gateway = await runner(
        found: [
          {
            'id': 'a',
            'name': 'Corrida São Paulo',
            'date': '2026-09-01',
            'city': 'São Paulo',
            'state': 'SP',
          },
        ],
        foundFor: (q) => q.toLowerCase().contains('são'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
            medalTextReader: _FakeReader(['Corrida Gão Paulo', '10 KM']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapAdd(tester);
      // Leu "Gão" (errado): nada achado, mas o campo é editável.
      expect(find.byKey(const Key('medal-match-a')), findsNothing);
      final nameField = find.byKey(const Key('medal-edit-name'));
      await tester.ensureVisible(nameField);
      expect(
        tester.widget<TextField>(nameField).controller!.text,
        'Corrida Gão Paulo',
      );
      await tester.enterText(nameField, 'Corrida São Paulo');
      await tester.ensureVisible(
        find.byKey(const Key('medal-scan-search-again')),
      );
      await tester.tap(find.byKey(const Key('medal-scan-search-again')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('medal-match-a')), findsOneWidget);
      // Corrige de novo, completa data e cidade e conclui: o formulário leva os dados editados.
      await tester.enterText(nameField, 'Meia São Paulo 2026');
      await tester.enterText(
        find.byKey(const Key('medal-edit-date')),
        '15/03/2026',
      );
      // Estado e cidade na rolagem (sem digitar): confirma a primeira da lista.
      await tester.ensureVisible(find.byKey(const Key('medal-edit-location')));
      await tester.tap(find.byKey(const Key('medal-edit-location')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location-done')));
      await tester.pumpAndSettle();
      expect(find.text('AC - Acrelândia'), findsOneWidget);
      final conclude = find.byKey(const Key('medal-scan-request'));
      await tester.ensureVisible(conclude);
      await tester.tap(conclude);
      await tester.pumpAndSettle();
      expect(find.byType(EditionRequestFormScreen), findsOneWidget);
      for (final text in ['Meia São Paulo 2026', '15/03/2026', '10']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      // Cidade e UF escolhidas na rolagem seguem para o formulário.
      expect(find.textContaining('Acrelândia'), findsWidgets);
    },
  );

  testWidgets(
    'tocar na corrida achada preenche o cadastro, e a data ganha as barras sozinha',
    (tester) async {
      final gateway = await runner(
        found: [
          {
            'id': 'a',
            'name': 'Meia Maratona de São Paulo',
            'date': '2026-09-20',
            'city': 'São Paulo',
            'state': 'SP',
            'distances': [
              {'id': '21k', 'kilometers': 21.0975},
            ],
          },
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
            medalTextReader: _FakeReader(['Meia Maratona']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapAdd(tester);
      String valueOf(String key) =>
          tester.widget<TextField>(find.byKey(Key(key))).controller!.text;
      expect(valueOf('medal-edit-name'), 'Meia Maratona');
      await tester.ensureVisible(find.byKey(const Key('medal-match-a')));
      await tester.tap(find.byKey(const Key('medal-match-a')));
      await tester.pumpAndSettle();
      // Nome, data, local e distância vieram da corrida escolhida, sem digitar.
      expect(valueOf('medal-edit-name'), 'Meia Maratona de São Paulo');
      expect(valueOf('medal-edit-date'), '20/09/2026');
      expect(valueOf('medal-edit-distance'), '21.0975');
      expect(find.text('SP - São Paulo'), findsOneWidget);
      expect(
        find.byType(EditionScreen),
        findsNothing,
      ); // tocar só preenche; abrir é o ícone
      // A data aceita só números e coloca as barras sozinha.
      final date = find.byKey(const Key('medal-edit-date'));
      await tester.ensureVisible(date);
      await tester.enterText(date, '15032026');
      await tester.pump();
      expect(valueOf('medal-edit-date'), '15/03/2026');
      await tester.enterText(date, '1503');
      await tester.pump();
      expect(valueOf('medal-edit-date'), '15/03');
      // O ícone abre a corrida.
      await tester.ensureVisible(find.byKey(const Key('medal-open-a')));
      await tester.tap(find.byKey(const Key('medal-open-a')));
      await tester.pumpAndSettle();
      expect(find.byType(EditionScreen), findsOneWidget);
    },
  );

  testWidgets(
    'com a corrida escolhida o botão Concluir fica disponível e abre o rascunho nela',
    (tester) async {
      final gateway = await runner(
        found: [
          {
            'id': 'a',
            'name': 'Meia Maratona de São Paulo',
            'date': '2026-09-20',
            'city': 'São Paulo',
            'state': 'SP',
            'distances': [
              {'id': '21k', 'kilometers': 21.0975},
            ],
          },
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
            medalTextReader: _FakeReader(['Meia Maratona']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapAdd(tester);
      // Antes de escolher a corrida, não há Concluir.
      expect(find.byKey(const Key('medal-scan-conclude')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('medal-match-a')));
      await tester.tap(find.byKey(const Key('medal-match-a')));
      await tester.pumpAndSettle();
      final conclude = find.byKey(const Key('medal-scan-conclude'));
      expect(conclude, findsOneWidget);
      await tester.ensureVisible(conclude);
      await tester.tap(conclude);
      await tester.pumpAndSettle();
      // Vai ao rascunho da participação na corrida escolhida (a foto segue junto quando existe).
      expect(find.byType(ParticipationDraftScreen), findsOneWidget);
      expect(find.text('Rascunho da participação'), findsOneWidget);
    },
  );

  testWidgets(
    'corrida com várias distâncias e sem km informado: pergunta a distância e abre a participação',
    (tester) async {
      final gateway = await runner(
        found: [
          {
            'id': 'a',
            'name': 'Meia de São Paulo',
            'date': '2026-09-20',
            'city': 'São Paulo',
            'state': 'SP',
            'distances': [
              {'id': '5k', 'kilometers': 5},
              {'id': '21k', 'kilometers': 21.0975},
            ],
          },
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
            medalTextReader: _FakeReader(['Meia de São Paulo']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapAdd(tester);
      await tester.ensureVisible(find.byKey(const Key('medal-match-a')));
      await tester.tap(find.byKey(const Key('medal-match-a')));
      await tester.pumpAndSettle();
      // A lista tem duas distâncias e nenhuma foi informada: pergunta ali mesmo, sem sair para a corrida.
      await tester.ensureVisible(find.byKey(const Key('medal-edit-distance')));
      await tester.enterText(find.byKey(const Key('medal-edit-distance')), '');
      final go = find.byKey(const Key('medal-scan-conclude'));
      await tester.ensureVisible(go);
      await tester.tap(go);
      await tester.pumpAndSettle();
      expect(find.text('Qual distância você correu?'), findsOneWidget);
      expect(find.byType(EditionScreen), findsNothing);
      await tester.tap(find.byKey(const Key('distance-option-21k')));
      await tester.pumpAndSettle();
      expect(find.byType(ParticipationDraftScreen), findsOneWidget);
      expect(find.text('Rascunho da participação'), findsOneWidget);
    },
  );

  testWidgets(
    'corrida em que já tenho participação: abre a participação, não só a corrida',
    (tester) async {
      final gateway = await runner(
        participationExists: true,
        found: [
          {
            'id': 'a',
            'name': 'Corrida A',
            'date': '2026-09-01',
            'city': 'São Paulo',
            'state': 'SP',
            'distances': [
              {'id': '10k', 'kilometers': 10},
            ],
          },
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
            medalTextReader: _FakeReader(['Corrida A']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapAdd(tester);
      await tester.ensureVisible(find.byKey(const Key('medal-match-a')));
      await tester.tap(find.byKey(const Key('medal-match-a')));
      await tester.pumpAndSettle();
      final go = find.byKey(const Key('medal-scan-conclude'));
      await tester.ensureVisible(go);
      await tester.tap(go);
      await tester.pumpAndSettle();
      expect(find.byType(ParticipationDraftScreen), findsOneWidget);
      expect(find.byType(EditionScreen), findsNothing);
    },
  );

  testWidgets(
    'concluir a participação de uma medalha nova volta à prateleira (sem tela preta)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = await runner(
        found: [
          {
            'id': 'a',
            'name': 'Corrida A',
            'date': '2026-09-01',
            'city': 'São Paulo',
            'state': 'SP',
            'distances': [
              {'id': '10k', 'kilometers': 10},
            ],
          },
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
            medalTextReader: _FakeReader(['Corrida A']),
            draftPhotoSelector: () async => [0xff, 0xd8, 0xff, 0xd9],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapAdd(tester);
      await tester.ensureVisible(find.byKey(const Key('medal-match-a')));
      await tester.tap(find.byKey(const Key('medal-match-a')));
      await tester.pumpAndSettle();
      final go = find.byKey(const Key('medal-scan-conclude'));
      await tester.ensureVisible(go);
      await tester.tap(go);
      await tester.pumpAndSettle();
      expect(find.text('Rascunho da participação'), findsOneWidget);
      await tester.tap(find.text('Selecionar foto'));
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
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
        final star = find.byKey(Key('rating-$label-5'));
        await tester.scrollUntilVisible(star, 200, scrollable: list);
        await tester.tap(star);
        await tester.pump();
      }
      final declaration = find.text('Declaro que concluí esta corrida');
      await tester.scrollUntilVisible(declaration, 200, scrollable: list);
      await tester.tap(declaration);
      await tester.pumpAndSettle();
      final finish = find.text('Concluir participação');
      await tester.scrollUntilVisible(finish, 200, scrollable: list);
      await tester.tap(finish);
      await tester.pumpAndSettle();
      // A prateleira aparece (não uma tela preta) e é a única tela: sem seta de voltar.
      expect(find.byType(MedalCollectionScreen), findsOneWidget);
      expect(find.byKey(const Key('medals-title')), findsOneWidget);
      expect(
        tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
        isFalse,
      );
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

  testWidgets('sem medalhas, a tela oferece adicionar a primeira pela foto', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MedalCollectionScreen(
          gateway: await runner(noRaces: true),
          medalPhotoPicker: (_) async => '/tmp/medalha.jpg',
          medalTextReader: _FakeReader(['CIRCUITO DAS ESTAÇÕES']),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Sua primeira medalha aparecerá aqui'),
      findsOneWidget,
    );
    // A tela do Rafael continua inteira: filtros e totais, com o convite no lugar da prateleira.
    expect(find.byKey(const Key('medals-list')), findsOneWidget);
    expect(find.text('Por ano'), findsOneWidget);
    expect(find.byKey(const Key('medals-empty')), findsOneWidget);
    expect(find.byType(CatalogScreen), findsNothing);
    await tester.tap(find.byKey(const Key('medal-add-first')));
    await tester.pumpAndSettle();
    expect(
      find.byType(MedalScanScreen),
      findsOneWidget,
    ); // vai direto à foto, não às corridas
    expect(find.byType(CatalogScreen), findsNothing);
  });

  Map<String, dynamic> medalRequest(
    String id,
    String status, {
    String? linked,
    String? reason,
  }) => {
    'id': id,
    'status': status,
    'version': 1,
    'details': {
      'name': 'Corrida $id',
      'date': '2027-03-14',
      'city': 'São Paulo',
      'distanceKm': 10,
      'imageReference': 'img_$id',
      'medalImageReference': 'img_med_$id',
    },
    'linkedEditionId': ?linked,
    'reason': ?reason,
  };

  testWidgets(
    'medalha provisória aparece cinza e com cadeado até a equipe aprovar',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: await runner(
              requests: [
                medalRequest('r1', 'pending'),
                medalRequest('r2', 'approved', linked: 'zz'),
                medalRequest('r3', 'rejected', reason: 'Prova duplicada'),
                medalRequest(
                  'r4',
                  'approved',
                  linked: 'a',
                ), // já concluída: some
                {
                  ...medalRequest('r5', 'pending'),
                  'details': {'name': 'Só pedido', 'date': '2027-03-14'},
                },
              ],
            ),
            pendingPhotoLoader: (_, _) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // As medalhas em análise ficam junto das minhas medalhas (na mesma prateleira), não numa seção à parte.
      expect(find.text('Medalhas em análise'), findsNothing);
      expect(find.byKey(const Key('medals-title')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byKey(const Key('pending-medal-r1')),
        ),
        findsOneWidget,
      );
      // Em análise: bloqueada, com cadeado.
      expect(find.byKey(const Key('pending-status-r1')), findsOneWidget);
      expect(find.text('Em análise pela equipe'), findsOneWidget);
      expect(find.byKey(const Key('pending-locked-r1-true')), findsOneWidget);
      // Aprovada: sem cinza nem cadeado, e convida a concluir.
      expect(find.byKey(const Key('pending-locked-r2-false')), findsOneWidget);
      expect(
        find.text('Corrida aprovada. Toque para concluir.'),
        findsOneWidget,
      );
      // Recusada: continua bloqueada e diz o motivo.
      expect(
        find.text('Cadastro não aprovado: Prova duplicada'),
        findsOneWidget,
      );
      // Aprovada e já concluída (corrida 'a'): a medalha de verdade já está na prateleira.
      expect(find.byKey(const Key('pending-medal-r4')), findsNothing);
      // Pedido comum, sem foto de medalha: não vira medalha provisória.
      expect(find.byKey(const Key('pending-medal-r5')), findsNothing);
      expect(
        find.byKey(const Key('pending-lock')),
        findsNWidgets(2),
      ); // r1 e r3
    },
  );

  testWidgets(
    'medalha aprovada: mostra o nome atual da corrida e leva à minha participação',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: await runner(
              noRaces: true,
              requests: [
                medalRequest('r2', 'approved', linked: 'b'),
                medalRequest('r1', 'pending'),
              ],
            ),
            pendingPhotoLoader: (_, _) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // O pedido dizia "Corrida r2"; a corrida aprovada tem o nome atual do catálogo.
      expect(find.byKey(const Key('pending-name-r2')), findsOneWidget);
      expect(find.text('Corrida B'), findsOneWidget);
      expect(find.text('Corrida r2'), findsNothing);
      // Aprovada: tem o lápis de editar, sem cadeado, e tocar leva ao rascunho da participação.
      expect(find.byKey(const Key('pending-edit-r2')), findsOneWidget);
      expect(find.byKey(const Key('pending-locked-r2-false')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pending-locked-r2-false')));
      await tester.pumpAndSettle();
      expect(find.byType(ParticipationDraftScreen), findsOneWidget);
      expect(find.text('Rascunho da participação'), findsOneWidget);
    },
  );

  testWidgets(
    'lápis da medalha em análise: menu com ver a solicitação e excluir',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: await runner(
              noRaces: true,
              requests: [medalRequest('r1', 'pending')],
            ),
            pendingPhotoLoader: (_, _) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pending-locked-r1-true')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pending-edit-r1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('pending-menu-continue')),
        findsNothing,
      ); // ainda não aprovada
      expect(find.byKey(const Key('pending-menu-delete')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pending-menu-request')));
      await tester.pumpAndSettle();
      expect(find.text('Minhas solicitações'), findsOneWidget);
    },
  );

  testWidgets(
    'excluir a medalha aprovada (Batman) pela prateleira: confirma, DELETE e some',
    (tester) async {
      final calls = <String>[];
      var deleted = false;
      final request = medalRequest('r9', 'approved', linked: 'b');
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
          calls.add(
            '$method ${uri.path}${uri.query.isEmpty ? '' : '?${uri.query}'}',
          );
          if (uri.path == '/me/participations') {
            return const JsonReply(200, {'items': []});
          }
          if (uri.path == '/me/edition-requests') {
            return JsonReply(200, {
              'items': deleted ? [] : [request],
            });
          }
          if (uri.path == '/edition-requests/r9' && method == 'DELETE') {
            deleted = true;
            return const JsonReply(200, {'id': 'r9', 'deleted': true});
          }
          if (uri.path == '/editions/b') {
            return JsonReply(
              200,
              edition('b', 'Batman Run', '2025-09-13', 'São Paulo', 'SP', 10),
            );
          }
          return const JsonReply(200, {'items': []});
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            pendingPhotoLoader: (_, _) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pending-medal-r9')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pending-edit-r9')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('pending-menu-continue')),
        findsOneWidget,
      ); // aprovada: dá para atualizar
      await tester.tap(find.byKey(const Key('pending-menu-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Excluir medalha?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(calls.any((c) => c.startsWith('DELETE')), isFalse);
      await tester.tap(find.byKey(const Key('pending-edit-r9')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pending-menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pending-delete-confirm')));
      await tester.pumpAndSettle();
      expect(
        calls
            .where((c) => c == 'DELETE /edition-requests/r9?expectedVersion=1')
            .length,
        1,
      );
      expect(find.byKey(const Key('pending-medal-r9')), findsNothing);
      expect(find.text('Medalha excluída.'), findsOneWidget);
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
