import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/pending_participation.dart';
import 'package:runpass/post_preview.dart';

// Dados [FICTICIA]. Antes de publicar, a pessoa vê a prévia da publicação e confirma (ou volta e edita).

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

Future<IdentityGateway> gateway() async {
  final g = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    sleeper: (_) async {},
    byteTransport: (uri, method, headers, bytes) async => 200,
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      if (uri.path == '/uploads') {
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
          'imageReference': 'img_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        });
      }
      return const JsonReply(404, {'code': 'NOT_FOUND'});
    },
  );
  await g.signIn('synthetic@example.test', 'synthetic');
  return g;
}

Future<void> tapKey(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  final list = find.byType(Scrollable).first;
  await tester.scrollUntilVisible(finder, 200, scrollable: list);
  final area = tester.getRect(list);
  for (var i = 0; i < 30; i++) {
    final y = tester.getCenter(finder).dy;
    if (y > area.top + 24 && y < area.bottom - 24) break;
    await tester.drag(list, Offset(0, y <= area.top + 24 ? 150 : -150));
    await tester.pump();
  }
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a prévia mostra quem posta, a corrida, tempo, texto e marcados; confirmar devolve verdadeiro',
    (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await confirmPostPreview(
                context,
                const PostPreviewData(
                  authorName: '[FICTICIA] Ana',
                  username: 'ana',
                  raceName: 'Corrida do Parque',
                  details: '10 km · 58:23',
                  text: 'Que corrida!',
                  tagged: ['beto', 'caio'],
                  photo: jpeg,
                ),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.text('Prévia da publicação'), findsOneWidget);
      expect(find.text('[FICTICIA] Ana'), findsOneWidget);
      expect(find.text('Corrida do Parque'), findsOneWidget);
      expect(find.text('10 km · 58:23'), findsOneWidget);
      expect(find.text('Que corrida!'), findsOneWidget);
      expect(find.text('Com @beto, @caio'), findsOneWidget);
      await tester.tap(find.byKey(const Key('post-preview-confirm')));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    },
  );

  testWidgets('voltar e editar não publica', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await confirmPostPreview(
              context,
              const PostPreviewData(
                authorName: 'Você',
                username: '',
                raceName: 'Corrida do Parque',
              ),
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    // Sem foto, sem texto e sem marcados: só o espaço reservado, e nada de linhas vazias.
    expect(find.byKey(const Key('post-preview-photo')), findsNothing);
    expect(find.byKey(const Key('post-preview-text')), findsNothing);
    expect(find.byKey(const Key('post-preview-tagged')), findsNothing);
    await tester.tap(find.byKey(const Key('post-preview-back')));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets(
    'pedido de corrida nova: publicando, mostra a prévia antes de enviar o cadastro',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Map<String, dynamic>? sent;
      final g = await gateway();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  sent = await Navigator.of(context).push<Map<String, dynamic>>(
                    MaterialPageRoute(
                      builder: (_) => PendingParticipationScreen(
                        gateway: g,
                        raceName: 'Corrida Nova',
                        distanceLabel: '5 km',
                        postPhotoSelector: (_) async => jpeg,
                      ),
                    ),
                  ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      for (final label in labels) {
        await tapKey(tester, Key('rating-$label-5'));
      }
      await tapKey(tester, const Key('pending-publish'));
      await tapKey(tester, const Key('pending-post-photo'));
      await tester.enterText(
        find.byKey(const Key('pending-post-text')),
        'Minha primeira!',
      );
      await tapKey(tester, const Key('pending-save'));
      // A prévia aparece e nada foi enviado ainda.
      expect(find.byKey(const Key('post-preview')), findsOneWidget);
      expect(find.text('Corrida Nova'), findsWidgets);
      expect(find.text('5 km'), findsOneWidget);
      expect(find.text('Minha primeira!'), findsWidgets);
      expect(sent, isNull);
      // Voltar e editar: segue no formulário.
      await tester.tap(find.byKey(const Key('post-preview-back')));
      await tester.pumpAndSettle();
      expect(sent, isNull);
      expect(find.byType(PendingParticipationScreen), findsOneWidget);
      // Confirmar: envia com a publicação.
      await tapKey(tester, const Key('pending-save'));
      await tester.tap(find.byKey(const Key('post-preview-confirm')));
      await tester.pumpAndSettle();
      expect(sent?['publishToFeed'], isTrue);
      expect(sent?['postText'], 'Minha primeira!');
      expect(find.byType(PendingParticipationScreen), findsNothing);
    },
  );

  testWidgets('pedido de corrida nova sem publicar: não mostra prévia', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Map<String, dynamic>? sent;
    final g = await gateway();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                sent = await Navigator.of(context).push<Map<String, dynamic>>(
                  MaterialPageRoute(
                    builder: (_) => PendingParticipationScreen(
                      gateway: g,
                      raceName: 'Corrida Nova',
                    ),
                  ),
                ),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    for (final label in labels) {
      await tapKey(tester, Key('rating-$label-5'));
    }
    await tapKey(tester, const Key('pending-save'));
    expect(find.byKey(const Key('post-preview')), findsNothing);
    expect(sent?['publishToFeed'], isFalse);
  });

  testWidgets(
    'pedido de corrida nova: "mesma nota para todos" preenche as 8 notas e o envio sai',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Map<String, dynamic>? sent;
      final g = await gateway();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  sent = await Navigator.of(context).push<Map<String, dynamic>>(
                    MaterialPageRoute(
                      builder: (_) => PendingParticipationScreen(
                        gateway: g,
                        raceName: 'Corrida Nova',
                      ),
                    ),
                  ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('same-rating-4'));
      await tapKey(tester, const Key('pending-save'));
      expect((sent?['ratings'] as Map).length, 8);
      expect((sent?['ratings'] as Map).values.every((v) => v == 4), isTrue);
    },
  );
}
