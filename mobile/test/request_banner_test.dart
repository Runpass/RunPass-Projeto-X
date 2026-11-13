import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/edition_requests.dart';
import 'package:runpass/identity_gateway.dart';

final onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class Setup {
  final IdentityGateway gateway;
  final List<String> calls;
  final List<Map<String, dynamic>?> requests;
  const Setup(this.gateway, this.calls, this.requests);
}

/// Gateway sintetico: o envio da imagem dá certo, ou falha na validação quando `uploadState` não é "valid".
Future<Setup> setup({
  String uploadState = 'valid',
  List<Map<String, dynamic>> mine = const [],
}) async {
  final calls = <String>[];
  final requests = <Map<String, dynamic>?>[];
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
        return JsonReply(200, {
          'uploadId': 'up1',
          'state': uploadState,
          if (uploadState == 'valid') 'imageReference': 'img_banner',
          if (uploadState == 'failed') 'reasonCode': 'INVALID_IMAGE',
        });
      }
      if (uri.path == '/edition-requests' && method == 'POST') {
        requests.add(body);
        return const JsonReply(201, {
          'id': 'r1',
          'version': 1,
          'status': 'pending',
        });
      }
      if (uri.path == '/me/edition-requests') {
        return JsonReply(200, {'items': mine});
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return Setup(gateway, calls, requests);
}

Future<void> fill(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  Future<void> type(String key, String value) async {
    final field = find.byKey(Key('request-$key'));
    await tester.ensureVisible(field);
    await tester.enterText(field, value);
  }

  await type('name', 'Corrida do Banner');
  await type('date', '14/03/2027');
  await type('distanceKm', '10');
}

Future<void> submit(WidgetTester tester) async {
  final button = find.byKey(const Key('request-submit'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Map<String, dynamic> listed(
  String status, {
  String? banner,
  bool image = true,
}) => {
  'id': 'r-$status${banner ?? ''}',
  'version': 2,
  'status': status,
  'details': {
    'name': 'Corrida $status',
    'date': '2027-03-14',
    'city': 'São Paulo',
    'distanceKm': 10,
    if (image) 'imageReference': 'img_banner',
  },
  'bannerState': ?banner,
};

void main() {
  test('situação do banner sugerido, em cada fase do pedido', () {
    expect(bannerStatusLabel('published', 'linked'), contains('publicado'));
    expect(
      bannerStatusLabel('dismissed', 'linked'),
      contains('não foi aprovado'),
    );
    expect(
      bannerStatusLabel(null, 'approved'),
      contains('aguardando a decisão'),
    );
    expect(bannerStatusLabel(null, 'linked'), contains('aguardando a decisão'));
    expect(
      bannerStatusLabel(null, 'pending'),
      contains('depois que a corrida for aprovada'),
    );
    expect(
      bannerStatusLabel(null, 'awaiting_load'),
      contains('depois que a corrida for aprovada'),
    );
    expect(bannerStatusLabel(null, 'rejected'), isNull);
  });

  testWidgets('sem banner o pedido segue como antes: nada é enviado', (
    tester,
  ) async {
    final s = await setup();
    await tester.pumpWidget(
      MaterialApp(home: EditionRequestFormScreen(gateway: s.gateway)),
    );
    await fill(tester);
    expect(find.byKey(const Key('request-banner')), findsOneWidget);
    expect(find.byKey(const Key('request-banner-preview')), findsNothing);
    await submit(tester);
    expect(s.calls, ['POST /edition-requests']);
    expect(s.requests.single!.containsKey('imageReference'), isFalse);
  });

  testWidgets('com banner: mostra a prévia, envia a imagem e o pedido leva só '
      'a referência', (tester) async {
    final s = await setup();
    await tester.pumpWidget(
      MaterialApp(
        home: EditionRequestFormScreen(
          gateway: s.gateway,
          bannerSelector: (context) async => onePixelPng,
        ),
      ),
    );
    await fill(tester);
    final pick = find.byKey(const Key('request-banner-pick'));
    await tester.ensureVisible(pick);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-banner-preview')), findsOneWidget);
    expect(find.byKey(const Key('request-banner-pick')), findsNothing);
    await submit(tester);
    expect(s.calls, [
      'POST /uploads',
      'POST /uploads/up1/finalize',
      'POST /edition-requests',
    ]);
    expect(s.requests.single!['imageReference'], 'img_banner');
    expect(s.requests.single!['name'], 'Corrida do Banner');
  });

  testWidgets('remover o banner volta a não enviar imagem', (tester) async {
    final s = await setup();
    await tester.pumpWidget(
      MaterialApp(
        home: EditionRequestFormScreen(
          gateway: s.gateway,
          bannerSelector: (context) async => onePixelPng,
        ),
      ),
    );
    await fill(tester);
    final pick = find.byKey(const Key('request-banner-pick'));
    await tester.ensureVisible(pick);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    final remove = find.byKey(const Key('request-banner-remove'));
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-banner-preview')), findsNothing);
    await submit(tester);
    expect(s.calls, ['POST /edition-requests']);
    expect(s.requests.single!.containsKey('imageReference'), isFalse);
  });

  testWidgets('imagem recusada pela validação: avisa, não cria o pedido', (
    tester,
  ) async {
    final s = await setup(uploadState: 'failed');
    await tester.pumpWidget(
      MaterialApp(
        home: EditionRequestFormScreen(
          gateway: s.gateway,
          bannerSelector: (context) async => onePixelPng,
        ),
      ),
    );
    await fill(tester);
    final pick = find.byKey(const Key('request-banner-pick'));
    await tester.ensureVisible(pick);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    await submit(tester);
    expect(
      find.text('A foto não foi aceita. Escolha outra imagem.'),
      findsOneWidget,
    );
    expect(s.requests, isEmpty); // o pedido não foi criado
    expect(s.calls, ['POST /uploads', 'POST /uploads/up1/finalize']);
  });

  testWidgets(
    'sugestão de banner de corrida cadastrada aparece como tal e mostra a situação',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await setup(
        mine: [
          {
            ...listed('linked'),
            'id': 'sug1',
            'kind': 'banner',
            'linkedEditionId': 'E1',
          },
        ],
      );
      await tester.pumpWidget(
        MaterialApp(home: MyEditionRequestsScreen(gateway: s.gateway)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Sugestão de banner para uma corrida já cadastrada'),
        findsOneWidget,
      );
      expect(find.textContaining('aguardando a decisão'), findsOneWidget);
    },
  );

  testWidgets('ao corrigir um pedido recusado não há campo de banner', (
    tester,
  ) async {
    final s = await setup();
    await tester.pumpWidget(
      MaterialApp(
        home: EditionRequestFormScreen(
          gateway: s.gateway,
          existing: {
            'id': 'r9',
            'version': 2,
            'status': 'rejected',
            'reason': 'faltou a fonte',
            'details': {
              'name': 'Corrida X',
              'date': '2027-03-14',
              'city': 'São Paulo',
              'distanceKm': 10,
            },
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-banner')), findsNothing);
  });

  testWidgets(
    'Minhas solicitações mostra a situação do banner de cada pedido',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await setup(
        mine: [
          listed('pending'),
          listed('linked'),
          listed('linked', banner: 'published'),
          listed('linked', banner: 'dismissed'),
          listed('rejected'),
          listed('linked', image: false),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(home: MyEditionRequestsScreen(gateway: s.gateway)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('banner-r-pending'))).data,
        contains('depois que a corrida for aprovada'),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('banner-r-linked'))).data,
        contains('aguardando a decisão'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('banner-r-linkedpublished')))
            .data,
        contains('publicado'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('banner-r-linkeddismissed')))
            .data,
        contains('não foi aprovado'),
      );
      // recusado ou sem imagem enviada: nenhuma linha de banner
      expect(find.byKey(const Key('banner-r-rejected')), findsNothing);
      expect(find.textContaining('Seu banner'), findsNWidgets(2));
    },
  );
}
