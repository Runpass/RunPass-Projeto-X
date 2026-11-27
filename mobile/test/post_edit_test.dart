import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';

const jpeg = [0xff, 0xd8, 0xff, 0xd9];

class Backend {
  final List<String> calls = [];
  final List<Map<String, dynamic>> patches = [];
  var uploads = 0;
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
        return JsonReply(200, {
          'uploadId': uri.pathSegments[1],
          'state': 'valid',
          'imageReference': 'img_novo${b.uploads}',
        });
      }
      if (uri.path == '/participations/c1' && method == 'PATCH') {
        final sent = Map<String, dynamic>.from(body! as Map);
        b.patches.add(sent);
        return JsonReply(200, {
          'id': 'c1',
          'editionId': 'E1',
          'distanceId': '5k',
          'state': 'completed',
          'version': (sent['expectedVersion'] as int) + 1,
          'publishToFeed': true,
          'medalImageReference': 'img_medalha',
          'postImageReference': sent['postImageReference'] ?? 'img_post_antiga',
          if (sent.containsKey('postText')) 'postText': sent['postText'],
        });
      }
      if (uri.path == '/participations/c1/review') {
        return const JsonReply(200, {
          'version': 1,
          'ratings': {
            'organization': 5,
            'course': 4,
            'kit': 4,
            'medal': 5,
            'hydration': 4,
            'facilities': 3,
            'safety': 4,
            'valueForMoney': 4,
          },
          'comment': 'Gostei',
        });
      }
      if (uri.path == '/editions/E1') {
        return const JsonReply(200, {
          'id': 'E1',
          'name': '[FICTICIA] Corrida',
          'date': '2024-09-22',
          'city': 'São Paulo',
          'state': 'SP',
          'status': 'past',
          'version': 1,
          'distances': [
            {'id': '5k', 'kilometers': 5},
            {'id': '10k', 'kilometers': 10},
          ],
        });
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return (gateway, b);
}

const published = {
  'id': 'c1',
  'editionId': 'E1',
  'distanceId': '5k',
  'state': 'completed',
  'version': 4,
  'publishToFeed': true,
  'medalImageReference': 'img_medalha',
  'postImageReference': 'img_post_antiga',
  'postText': 'Texto antigo',
  'timeSeconds': 1800,
};

Future<void> open(
  WidgetTester tester,
  IdentityGateway gateway, {
  bool fromPost = true,
  Map<String, dynamic> initial = published,
  Future<List<int>?> Function(IdentityGateway, String)? loader,
  Future<List<int>?> Function(BuildContext, List<int>)? cropper,
  PhotoSelector? selector,
}) async {
  tester.view.physicalSize = const Size(800, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: ParticipationDraftScreen(
        gateway: gateway,
        initial: initial,
        fromPost: fromPost,
        postPhotoLoader: loader ?? (_, _) async => jpeg,
        postPhotoCropper: cropper ?? (context, photo) async => photo,
        postPhotoSelector: selector,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(draftFormCache.clear);

  testWidgets(
    'editar pela publicação ajusta a foto da publicação, não a da medalha',
    (tester) async {
      final (gateway, _) = await setup();
      await open(tester, gateway);
      expect(find.byKey(const Key('post-photos-editor')), findsOneWidget);
      expect(find.byKey(const Key('post-photo-thumb-0')), findsOneWidget);
      expect(
        find.byKey(const Key('change-medal-photo')),
        findsNothing,
      ); // a medalha se edita em Medalhas
      // As informações da corrida continuam editáveis: tempo, distância, colocação, peito e avaliação.
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('distance-field')),
        200,
        scrollable: list,
      );
      expect(find.byKey(const Key('time-field')), findsOneWidget);
      // A avaliação se edita na própria tela (sem botão que abra outra).
      await tester.scrollUntilVisible(
        find.byKey(const Key('review-comment-inline')),
        200,
        scrollable: list,
      );
      expect(find.text('Editar avaliação'), findsNothing);
      expect(find.text('Salvar avaliação'), findsNothing);
      expect(find.byKey(const Key('review-comment-inline')), findsOneWidget);
    },
  );

  testWidgets('vindo de Medalhas, a edição segue com a foto da medalha', (
    tester,
  ) async {
    final (gateway, _) = await setup();
    await open(tester, gateway, fromPost: false);
    expect(find.byKey(const Key('change-medal-photo')), findsOneWidget);
    expect(find.byKey(const Key('post-photos-editor')), findsNothing);
    expect(find.byKey(const Key('post-photo-thumb-0')), findsNothing);
  });

  testWidgets(
    'ajustar o tamanho baixa a foto atual, recorta, envia e grava só a foto da publicação',
    (tester) async {
      final (gateway, b) = await setup();
      final loaded = <String>[];
      var cropped = false;
      await open(
        tester,
        gateway,
        loader: (_, id) async {
          loaded.add(id);
          return jpeg;
        },
        cropper: (context, photo) async {
          cropped = true;
          return [...photo, 0x00];
        },
      );
      await tester.tap(find.byKey(const Key('post-photo-thumb-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-photo-adjust')));
      await tester.pumpAndSettle();
      expect(loaded, ['c1']);
      expect(cropped, isTrue);
      expect(b.uploads, 1);
      expect(b.patches.single['postImageReference'], 'img_novo1');
      expect(b.patches.single['expectedVersion'], 4);
      expect(
        b.patches.single.containsKey('medalImageReference'),
        isFalse,
      ); // a medalha não muda
      expect(
        find.text('Tamanho da foto da publicação ajustado.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('desistir do recorte não envia nada', (tester) async {
    final (gateway, b) = await setup();
    await open(tester, gateway, cropper: (_, _) async => null);
    await tester.tap(find.byKey(const Key('post-photo-thumb-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('post-photo-adjust')));
    await tester.pumpAndSettle();
    expect(b.uploads, 0);
    expect(b.patches, isEmpty);
  });

  testWidgets('foto da publicação que não baixa mostra o aviso e não grava', (
    tester,
  ) async {
    final (gateway, b) = await setup();
    await open(tester, gateway, loader: (_, _) async => null);
    await tester.tap(find.byKey(const Key('post-photo-thumb-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('post-photo-adjust')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Não foi possível abrir a foto da publicação'),
      findsOneWidget,
    );
    expect(b.patches, isEmpty);
  });

  testWidgets('trocar a foto da publicação envia outra foto e grava', (
    tester,
  ) async {
    final (gateway, b) = await setup();
    await open(tester, gateway, selector: () async => jpeg);
    await tester.tap(find.byKey(const Key('post-photo-thumb-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('post-photo-replace')));
    await tester.pumpAndSettle();
    expect(b.patches.single['postImageReference'], 'img_novo1');
    expect(find.text('Foto da publicação trocada.'), findsOneWidget);
  });

  testWidgets(
    'o texto da publicação vem preenchido e pode ser salvo ou apagado',
    (tester) async {
      final (gateway, b) = await setup();
      await open(tester, gateway);
      final field = find.byKey(const Key('post-text-edit'));
      expect(tester.widget<TextField>(field).controller!.text, 'Texto antigo');
      await tester.enterText(field, '  Novo texto  ');
      await tester.tap(find.byKey(const Key('save-post-text')));
      await tester.pumpAndSettle();
      expect(b.patches.last['postText'], 'Novo texto');
      await tester.enterText(field, '   ');
      await tester.tap(find.byKey(const Key('save-post-text')));
      await tester.pumpAndSettle();
      expect(b.patches.last['postText'], isNull);
      expect(b.patches.last.containsKey('postText'), isTrue); // nulo apaga
    },
  );

  testWidgets('salvar o texto da publicação volta para a tela anterior', (
    tester,
  ) async {
    final (gateway, b) = await setup();
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('abrir'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ParticipationDraftScreen(
                      gateway: gateway,
                      initial: published,
                      fromPost: true,
                      postPhotoLoader: (_, _) async => jpeg,
                    ),
                  ),
                ),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('abrir')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('post-text-edit')),
      'Novo texto',
    );
    await tester.tap(find.byKey(const Key('save-post-text')));
    await tester.pumpAndSettle();
    expect(b.patches.last['postText'], 'Novo texto');
    expect(find.byType(ParticipationDraftScreen), findsNothing);
    expect(find.byKey(const Key('abrir')), findsOneWidget);
    expect(find.text('Texto da publicação salvo.'), findsOneWidget);
  });

  testWidgets(
    'a medalha concluída mostra o nome da corrida embaixo da foto e sem as frases de apoio',
    (tester) async {
      final (gateway, _) = await setup();
      await open(tester, gateway, fromPost: false);
      final name = find.byKey(const Key('race-name-under-photo'));
      expect(name, findsOneWidget);
      expect(find.text('[FICTICIA] Corrida'), findsOneWidget);
      // O nome vem logo abaixo da foto (antes do botão de trocar a foto).
      final photo = tester.getRect(find.byType(ClipRRect).first);
      expect(tester.getTopLeft(name).dy, greaterThanOrEqualTo(photo.bottom));
      expect(
        tester.getTopLeft(name).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('change-medal-photo'))).dy,
        ),
      );
      // Sem as frases embaixo do botão de trocar a foto.
      expect(
        find.textContaining(
          'Participação concluída · medalha e avaliação registradas',
        ),
        findsNothing,
      );
      expect(find.textContaining('Conquista não publicada'), findsNothing);
      expect(find.textContaining('Conquista publicada'), findsNothing);
    },
  );

  testWidgets('tocar no nome da corrida abre as informações da corrida', (
    tester,
  ) async {
    final (gateway, _) = await setup();
    await open(tester, gateway, fromPost: false);
    expect(find.byKey(const Key('race-name-open')), findsOneWidget);
    expect(find.byType(EditionScreen), findsNothing);
    await tester.tap(find.byKey(const Key('race-name-open')));
    await tester.pumpAndSettle();
    expect(find.byType(EditionScreen), findsOneWidget);
    final screen = tester.widget<EditionScreen>(find.byType(EditionScreen));
    expect(screen.editionId, published['editionId']);
  });
}
