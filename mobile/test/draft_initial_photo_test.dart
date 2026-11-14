import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';

final onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<(IdentityGateway, List<String>)> setup() async {
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
}
