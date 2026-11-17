import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';

final onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<(IdentityGateway, List<String>)> setup({String? officialUrl}) async {
  final calls = <String>[];
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
          'imageReference': 'img_ok',
        });
      }
      if (uri.path == '/participations/d5/review') {
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
          'comment': 'Percurso bonito e bem sinalizado',
        });
      }
      if (uri.path == '/participations/d5' && method == 'PATCH') {
        return JsonReply(200, {
          'id': 'd5',
          'editionId': 'E1',
          'distanceId': '5k',
          'state': 'completed',
          'version': 3,
          'showTime': (body! as Map)['showTime'] ?? true,
          'showPlacement': (body as Map)['showPlacement'] ?? true,
        });
      }
      if (uri.path == '/editions/E1') {
        return JsonReply(200, {
          'officialUrl': ?officialUrl,
          'id': 'E1',
          'name': '[FICTICIA] Corrida',
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
  return (gateway, calls);
}

void main() {
  setUp(draftFormCache.clear);

  testWidgets(
    'a foto que já veio escolhida (medalha) é enviada ao abrir o rascunho',
    (tester) async {
      final (gateway, calls) = await setup();
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'd1',
              'editionId': 'E1',
              'distanceId': '5k',
              'state': 'draft',
              'version': 1,
            },
            initialPhoto: onePixelPng,
            initialPhotoCropper: (context, photo) async => photo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.startsWith('POST /uploads')), [
        'POST /uploads',
        'POST /uploads/up1/finalize',
      ]);
      expect(
        find.text('Foto validada e privada. Ainda não foi publicada.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('sem foto inicial, nada é enviado sozinho', (tester) async {
    final (gateway, calls) = await setup();
    await tester.pumpWidget(
      MaterialApp(
        home: ParticipationDraftScreen(
          gateway: gateway,
          initial: const {
            'id': 'd2',
            'editionId': 'E1',
            'distanceId': '5k',
            'state': 'draft',
            'version': 1,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.startsWith('POST /uploads')), isEmpty);
  });

  testWidgets('desistir do recorte da foto inicial não envia nada', (
    tester,
  ) async {
    final (gateway, calls) = await setup();
    await tester.pumpWidget(
      MaterialApp(
        home: ParticipationDraftScreen(
          gateway: gateway,
          initial: const {
            'id': 'd3',
            'editionId': 'E1',
            'distanceId': '5k',
            'state': 'draft',
            'version': 1,
          },
          initialPhoto: onePixelPng,
          initialPhotoCropper: (context, photo) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.startsWith('POST /uploads')), isEmpty);
    expect(find.textContaining('Foto não enviada'), findsOneWidget);
  });

  testWidgets(
    'avaliação e comentário já aparecem sem foto; concluir só com a foto',
    (tester) async {
      final (gateway, calls) = await setup();
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'd4',
              'editionId': 'E1',
              'distanceId': '5k',
              'state': 'draft',
              'version': 1,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Avaliação obrigatória'), findsOneWidget);
      expect(find.text('Comentário (opcional)'), findsOneWidget);
      expect(find.byKey(const Key('needs-photo-hint')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Concluir participação'),
            )
            .onPressed,
        isNull,
      );
      expect(calls.where((c) => c.startsWith('POST')), isEmpty);
    },
  );

  testWidgets(
    'corrida de uma distância só já vem com a distância escolhida e o Já corri habilitado',
    (tester) async {
      final (gateway, _) = await setup();
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: EditionScreen(gateway: gateway, editionId: 'E1'),
        ),
      );
      await tester.pumpAndSettle();
      final ran = find.byKey(const Key('plan-ran'));
      await tester.scrollUntilVisible(
        ran,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(ran, findsOneWidget); // sem tocar na distância antes
      expect(
        find.text('Escolha uma distância para registrar que você já correu.'),
        findsNothing,
      );
      expect(find.text('Minha situação nesta corrida'), findsNothing);
    },
  );

  testWidgets(
    'medalha concluída: sem botão Salvar visibilidade (chaves gravam sozinhas) e com o meu comentário',
    (tester) async {
      final (gateway, calls) = await setup();
      tester.view.physicalSize = const Size(800, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ParticipationDraftScreen(
            gateway: gateway,
            initial: const {
              'id': 'd5',
              'editionId': 'E1',
              'distanceId': '5k',
              'state': 'completed',
              'version': 2,
              'showTime': true,
              'showPlacement': true,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Salvar visibilidade'), findsNothing);
      // O comentário que escrevi aparece nesta tela, num campo que já dá para editar.
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
        'Percurso bonito e bem sinalizado',
      );
      // Mudar a chave grava na hora.
      await tester.ensureVisible(find.byKey(const Key('show-time-switch')));
      await tester.tap(find.byKey(const Key('show-time-switch')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c == 'PATCH /participations/d5').length, 1);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('show-time-switch')))
            .value,
        isFalse,
      );
    },
  );

  testWidgets(
    'toda corrida tem o ícone do site: o oficial, ou a busca na internet quando não há',
    (tester) async {
      final opened = <Uri>[];
      final previous = linkOpener;
      linkOpener = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => linkOpener = previous);
      Future<void> pump(IdentityGateway gateway) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: EditionScreen(gateway: gateway, editionId: 'E1'),
          ),
        );
        await tester.pumpAndSettle();
      }

      final (withSite, _) = await setup(
        officialUrl: 'https://corrida.example/site',
      );
      await pump(withSite);
      expect(find.byTooltip('Site da corrida'), findsOneWidget);
      await tester.tap(find.byKey(const Key('hero-site')));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), 'https://corrida.example/site');

      opened.clear();
      final (noSite, _) = await setup();
      await pump(noSite);
      expect(find.byTooltip('Buscar o site da corrida'), findsOneWidget);
      await tester.tap(find.byKey(const Key('hero-site')));
      await tester.pumpAndSettle();
      expect(opened.single.host, 'www.google.com');
      expect(
        opened.single.queryParameters['q'],
        contains('[FICTICIA] Corrida'),
      );
    },
  );
}
