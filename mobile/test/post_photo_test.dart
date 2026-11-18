import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/new_post.dart';

const jpeg = [0xff, 0xd8, 0xff, 0xd9];
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

class Backend {
  final List<String> calls = [];
  Map<String, dynamic>? completion;
  Map<String, dynamic>? published;
  var uploads = 0;
  // A segunda foto enviada tem referência diferente (a mesma foto teria a mesma referência).
  String Function(int n) referenceFor = (n) =>
      n == 1 ? 'img_medal' : 'img_post';
  List<Map<String, dynamic>> participations = [];
}

Future<(IdentityGateway, Backend)> setup() async {
  final b = Backend();
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
      b.calls.add('$method ${uri.path}');
      if (uri.path == '/uploads') {
        b.uploads++;
        return JsonReply(201, {
          'uploadId': 'up${b.uploads}',
          'uploadUrl': 'https://signed.example/up${b.uploads}',
          'uploadMethod': 'PUT',
          'uploadHeaders': {'Content-Type': 'image/jpeg'},
        });
      }
      if (uri.path.endsWith('/finalize')) {
        final n = int.parse(uri.pathSegments[1].substring(2));
        return JsonReply(200, {
          'uploadId': 'up$n',
          'state': 'valid',
          'imageReference': b.referenceFor(n),
        });
      }
      if (uri.path == '/participations/d1/complete') {
        b.completion = Map<String, dynamic>.from(body! as Map);
        return const JsonReply(200, {
          'id': 'd1',
          'editionId': 'E1',
          'distanceId': '5k',
          'state': 'completed',
          'version': 3,
        });
      }
      if (uri.path.endsWith('/publish') && method == 'POST') {
        b.published = Map<String, dynamic>.from(body! as Map);
        return const JsonReply(200, {'id': 'c1', 'publishToFeed': true});
      }
      if (uri.path == '/me/participations') {
        return JsonReply(200, {'items': b.participations});
      }
      if (uri.path.startsWith('/editions/')) {
        return JsonReply(200, {
          'id': uri.pathSegments.last,
          'name': 'Corrida ${uri.pathSegments.last}',
          'date': '2024-09-22',
          'city': 'São Paulo',
          'state': 'SP',
          'status': 'past',
          'version': 1,
          'distances': [
            {'id': '5k', 'kilometers': 5},
          ],
        });
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return (gateway, b);
}

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> rateAndDeclare(WidgetTester tester) async {
  final list = find.byType(Scrollable).first;
  final finish = find.text('Concluir participação');
  await tester.scrollUntilVisible(finish, 200, scrollable: list);
  for (final label in labels) {
    final star = find.byKey(Key('rating-$label-5'));
    await tester.scrollUntilVisible(star, 200, scrollable: list);
    await tester.tap(star);
    await tester.pump();
  }
  final declaration = find.text('Declaro que concluí esta corrida');
  await tester.scrollUntilVisible(declaration, 200, scrollable: list);
  await tester.tap(declaration);
  await tester.pumpAndSettle();
}

void main() {
  setUp(draftFormCache.clear);

  testWidgets(
    'publicar no feed pede outra foto, separada da medalha, e a envia junto',
    (tester) async {
      tall(tester);
      final (gateway, b) = await setup();
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'd1',
              'editionId': 'E1',
              'distanceId': '5k',
              'state': 'draft',
              'version': 2,
            },
            photoSelector: () async => jpeg,
            postPhotoSelector: () async => jpeg,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Selecionar foto'));
      await tester.pumpAndSettle();
      await rateAndDeclare(tester);
      final list = find.byType(Scrollable).first;
      final finishButton = find.widgetWithText(
        FilledButton,
        'Concluir participação',
      );
      // Sem publicar, só a foto da medalha basta.
      await tester.scrollUntilVisible(finishButton, 200, scrollable: list);
      expect(tester.widget<FilledButton>(finishButton).onPressed, isNotNull);
      expect(find.byKey(const Key('select-post-photo')), findsNothing);
      // Marcou publicar: a foto da medalha já vira a foto do post (envio próprio, referência diferente)...
      final publish = find.byKey(const Key('publish-to-feed'));
      await tester.scrollUntilVisible(publish, -200, scrollable: list);
      await tester.tap(publish);
      await tester.pumpAndSettle();
      expect(b.uploads, 2);
      expect(find.byKey(const Key('select-post-photo')), findsOneWidget);
      expect(find.byKey(const Key('post-photo-ok')), findsOneWidget);
      expect(find.byKey(const Key('use-medal-for-post')), findsOneWidget);
      await tester.scrollUntilVisible(finishButton, 200, scrollable: list);
      expect(tester.widget<FilledButton>(finishButton).onPressed, isNotNull);
      // ...e a pessoa pode escolher outra foto para o post (terceiro envio).
      await tester.scrollUntilVisible(
        find.byKey(const Key('select-post-photo')),
        -200,
        scrollable: list,
      );
      await tester.tap(find.byKey(const Key('select-post-photo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('post-photo-ok')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('post-text-field')),
        'Que corrida!',
      );
      await tester.scrollUntilVisible(finishButton, 200, scrollable: list);
      expect(tester.widget<FilledButton>(finishButton).onPressed, isNotNull);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      // Antes de publicar, a prévia: voltar e editar não conclui nada; confirmar conclui.
      expect(find.byKey(const Key('post-preview')), findsOneWidget);
      expect(find.byKey(const Key('post-preview-photo')), findsOneWidget);
      expect(find.text('Que corrida!'), findsWidgets);
      await tester.tap(find.byKey(const Key('post-preview-back')));
      await tester.pumpAndSettle();
      expect(b.completion, isNull);
      await tester.ensureVisible(finishButton);
      await tester.tap(finishButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-preview-confirm')));
      await tester.pumpAndSettle();
      expect(
        b.uploads,
        3,
      ); // medalha, cópia da medalha para o post e a outra foto escolhida
      expect(b.completion?['medalImageReference'], 'img_medal');
      expect(b.completion?['postImageReference'], isNot('img_medal'));
      expect(b.completion?['postText'], 'Que corrida!');
      expect(b.completion?['publishToFeed'], isTrue);
    },
  );

  testWidgets('a foto da medalha não serve de foto da publicação', (
    tester,
  ) async {
    tall(tester);
    final (gateway, b) = await setup();
    b.referenceFor = (n) => 'img_igual'; // mesma foto, mesma referência
    await tester.pumpWidget(
      MaterialApp(
        home: ParticipationDraftScreen(
          gateway: gateway,
          initial: const {
            'id': 'd1',
            'editionId': 'E1',
            'distanceId': '5k',
            'state': 'draft',
            'version': 2,
          },
          photoSelector: () async => jpeg,
          postPhotoSelector: () async => jpeg,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selecionar foto'));
    await tester.pumpAndSettle();
    final list = find.byType(Scrollable).first;
    final publish = find.byKey(const Key('publish-to-feed'));
    await tester.scrollUntilVisible(publish, 200, scrollable: list);
    await tester.tap(publish);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('select-post-photo')),
      200,
      scrollable: list,
    );
    await tester.tap(find.byKey(const Key('select-post-photo')));
    await tester.pumpAndSettle();
    expect(find.textContaining('foto diferente da medalha'), findsWidgets);
    expect(find.byKey(const Key('post-photo-ok')), findsNothing);
  });

  testWidgets(
    '"+" da Home abre a nova postagem; só aparecem corridas ainda não publicadas',
    (tester) async {
      tall(tester);
      final (gateway, b) = await setup();
      b.participations = [
        {
          'id': 'c1',
          'editionId': 'E1',
          'distanceId': '5k',
          'state': 'completed',
          'version': 4,
          'publishToFeed': false,
          'completedAt': '2026-11-01T10:00:00Z',
          'medalImageReference': 'img_medal',
        },
        {
          'id': 'c2',
          'editionId': 'E2',
          'distanceId': '5k',
          'state': 'completed',
          'version': 3,
          'publishToFeed': true, // já publicada: não entra na lista
          'completedAt': '2026-10-01T10:00:00Z',
        },
      ];
      await tester.pumpWidget(
        MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-post')), findsOneWidget);
      expect(find.byTooltip('Nova postagem'), findsOneWidget);
      await tester.tap(find.byKey(const Key('new-post')));
      await tester.pumpAndSettle();
      expect(find.byType(NewPostScreen), findsOneWidget);
      expect(find.byKey(const Key('new-post-race-c1')), findsOneWidget);
      expect(find.byKey(const Key('new-post-race-c2')), findsNothing);
    },
  );

  testWidgets(
    'nova postagem: escolhe a corrida, a foto e publica com a versão da participação',
    (tester) async {
      tall(tester);
      final (gateway, b) = await setup();
      b.participations = [
        {
          'id': 'c1',
          'editionId': 'E1',
          'distanceId': '5k',
          'state': 'completed',
          'version': 4,
          'publishToFeed': false,
          'completedAt': '2026-11-01T10:00:00Z',
          'medalImageReference': 'img_medal',
        },
      ];
      b.referenceFor = (n) => 'img_post';
      await tester.pumpWidget(
        MaterialApp(
          home: NewPostScreen(
            gateway: gateway,
            photoSelector: (_) async => jpeg,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('new-post-photo')),
        findsNothing,
      ); // antes de escolher a corrida
      await tester.tap(find.byKey(const Key('new-post-race-c1')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('new-post-publish')))
            .onPressed,
        isNull,
      ); // sem foto, não publica
      await tester.tap(find.byKey(const Key('new-post-photo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-post-preview')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('new-post-text')),
        'Minha prova',
      );
      await tester.tap(find.byKey(const Key('new-post-publish')));
      await tester.pumpAndSettle();
      expect(b.calls, contains('POST /participations/c1/publish'));
      expect(b.published, {
        'expectedVersion': 4,
        'postImageReference': 'img_post',
        'postText': 'Minha prova',
      });
    },
  );

  testWidgets(
    'nova postagem: "Adicionar outra corrida" usa o fluxo da medalha e avisa quando virou pedido',
    (tester) async {
      final (gateway, _) = await setup();
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NewPostScreen(
            gateway: gateway,
            addRace: (context) async {
              opened++;
              return 'request';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-post-add-race')));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(find.textContaining('Pedido de cadastro enviado'), findsOneWidget);
    },
  );

  testWidgets('sem corrida concluída para publicar a tela explica', (
    tester,
  ) async {
    final (gateway, _) = await setup();
    await tester.pumpWidget(MaterialApp(home: NewPostScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new-post-empty')), findsOneWidget);
  });

  testWidgets(
    'a foto do feed usa o endereço próprio quando a publicação tem foto separada',
    (tester) async {
      final (gateway, b) = await setup();
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              SizedBox(
                height: 40,
                child: MedalPhoto(
                  gateway: gateway,
                  participationId: 'c1',
                  usePostImage: true,
                ),
              ),
              SizedBox(
                height: 40,
                child: MedalPhoto(gateway: gateway, participationId: 'c2'),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(b.calls, contains('GET /participations/c1/post-image'));
      expect(b.calls, contains('GET /participations/c2/image'));
      expect(
        const RaceRecord({'postImageReference': 'img_x'}, null).hasPostImage,
        isTrue,
      );
      expect(
        const RaceRecord({'hasPostImage': true}, null).hasPostImage,
        isTrue,
      );
      expect(const RaceRecord({'id': 'c'}, null).hasPostImage, isFalse);
    },
  );

  testWidgets(
    'ao tocar na medalha aparece a foto da medalha; a da publicação só vem pela publicação',
    (tester) async {
      tall(tester);
      const medal = {
        'id': 'c1',
        'editionId': 'E1',
        'distanceId': '5k',
        'state': 'completed',
        'version': 4,
        'hasPostImage': true,
      };
      final (gateway, b) = await setup();
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(gateway: gateway, initial: medal),
        ),
      );
      await tester.pumpAndSettle();
      expect(b.calls, contains('GET /participations/c1/image'));
      expect(b.calls, isNot(contains('GET /participations/c1/post-image')));
      b.calls.clear();
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            key: const Key('da-publicacao'),
            gateway: gateway,
            initial: medal,
            fromPost: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(b.calls, contains('GET /participations/c1/post-image'));
    },
  );

  testWidgets(
    'sair e voltar ao rascunho mantém a foto e o texto da publicação',
    (tester) async {
      tall(tester);
      final (gateway, _) = await setup();
      Widget draft() => MaterialApp(
        home: ParticipationDraftScreen(
          gateway: gateway,
          initial: const {
            'id': 'd1',
            'editionId': 'E1',
            'distanceId': '5k',
            'state': 'draft',
            'version': 2,
          },
          photoSelector: () async => jpeg,
          postPhotoSelector: () async => jpeg,
        ),
      );
      await tester.pumpWidget(draft());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Selecionar foto'));
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      final publish = find.byKey(const Key('publish-to-feed'));
      await tester.scrollUntilVisible(publish, 200, scrollable: list);
      await tester.tap(publish);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-post-photo')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('post-text-field')),
        'Texto guardado',
      );
      await tester.pumpWidget(const SizedBox()); // sai da tela
      await tester.pumpWidget(draft()); // volta ao mesmo rascunho
      await tester.pumpAndSettle();
      final again = find.byKey(const Key('post-photo-ok'));
      await tester.scrollUntilVisible(
        again,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(again, findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('post-text-field')))
            .controller!
            .text,
        'Texto guardado',
      );
    },
  );

  testWidgets(
    'voltar da tela da medalha recarrega a foto da prateleira (foto trocada aparece)',
    (tester) async {
      tall(tester);
      final (gateway, b) = await setup();
      b.participations = [
        {
          'id': 'c1',
          'editionId': 'E1',
          'distanceId': '5k',
          'state': 'completed',
          'version': 4,
          'publishToFeed': false,
          'completedAt': '2026-11-01T10:00:00Z',
          'medalImageReference': 'img_medalha',
        },
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: MedalCollectionScreen(
            gateway: gateway,
            pendingPhotoLoader: (_, _) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      int shelfPhotoRequests() => b.calls
          .where((c) => c == 'GET /participations/c1/display-image')
          .length;
      final first = shelfPhotoRequests();
      expect(first, greaterThanOrEqualTo(1));
      await tester.tap(find.text('Corrida E1').first);
      await tester.pumpAndSettle();
      expect(find.byType(ParticipationDraftScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      // Ao voltar a prateleira busca de novo a foto (antes ficava com a foto velha na tela).
      expect(shelfPhotoRequests(), greaterThan(first));
    },
  );
}
