import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/demo_transport.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/main.dart';

/// PNG valido de 1x1 pixel: a foto escolhida aparece na tela de cadastro.
final onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

IdentityGateway demoGateway(DemoTransport demo) => IdentityGateway(
  cognito: Uri.parse('https://cognito.demo.invalid'),
  api: Uri.parse('https://api.demo.invalid'),
  clientId: 'synthetic-client',
  transport: demo.call,
  byteTransport: demo.putBytes,
);

void main() {
  testWidgets(
    'clearly labelled local demo goes from login through profile and admission to catalog',
    (tester) async {
      final gateway = demoGateway(DemoTransport());
      await tester.pumpWidget(
        MainApp(
          gateway: gateway,
          demonstration: true,
          photoPicker: (context, choice) async => onePixelPng,
        ),
      );
      expect(find.textContaining('DEMONSTRAÇÃO LOCAL'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'E-mail'),
        'demo@runpass.test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Senha'),
        'RunpassDemo123!',
      );
      await tester.ensureVisible(find.text('Entrar'));
      await tester.tap(find.text('Entrar'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome de exibição'),
        'Corredor Demo',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome de usuário'),
        'corredor_demo',
      );
      await tester.ensureVisible(find.text('Continuar'));
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('location-field')));
      await tester.tap(find.byKey(const Key('location-field')));
      await tester.pumpAndSettle();
      // Aceita o estado/cidade padrao do seletor (primeiro da lista: Acre/Acrelândia).
      await tester.tap(find.byKey(const Key('location-done')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Continuar'));
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('birth-date-field')));
      await tester.tap(find.byKey(const Key('birth-date-field')));
      await tester.pumpAndSettle();
      // Aceita a data padrao do seletor (hoje menos 18 anos), que ja e elegivel.
      await tester.tap(find.byKey(const Key('birth-date-done')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Continuar'));
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      // Cadastro novo: a foto de perfil e obrigatoria antes de entrar.
      expect(find.text('Sua foto de perfil'), findsOneWidget);
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(find.text('Escolha uma foto para continuar.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('choose-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-gallery')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Continuar'));
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      // After admission the runner lands on Início, not on the catalog.
      // The demo feed carries fictional posts by other runners.
      expect(find.text('Mariana Lopes'), findsOneWidget);
      expect(find.text('Encontre sua próxima conquista'), findsNothing);
      await tester.tap(find.text('Corridas'));
      await tester.pumpAndSettle();
      expect(find.text('Encontre sua próxima conquista'), findsNothing);
      await tester.tap(find.byKey(const Key('catalog-search-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Encontre sua próxima conquista'), findsOneWidget);
      // Ordem padrão: mais recentes primeiro (o seletor aparece com a lista carregada).
      await tester.scrollUntilVisible(
        find.byKey(const Key('catalog-sort')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('catalog-sort')), findsOneWidget);
      await tester.tap(find.text('Início'));
      await tester.pumpAndSettle();
      // The demo feed carries fictional posts by other runners.
      expect(find.text('Mariana Lopes'), findsOneWidget);
      await tester.tap(find.text('Medalhas'));
      await tester.pumpAndSettle();
      expect(find.text('Minhas Medalhas'), findsOneWidget);
      await tester.tap(find.text('Perfil'));
      await tester.pumpAndSettle();
      expect(find.text('Corredor Demo'), findsOneWidget);
    },
  );

  test(
    'demo signup and confirmation never contact a network service',
    () async {
      final gateway = demoGateway(DemoTransport());
      await gateway.signUp('new@runpass.test');
      await gateway.confirm('new@runpass.test', '123456');
      // setPassword ja entra com a senha temporaria e troca pela senha real; a sessao
      // segue autenticada, como num signIn comum.
      await gateway.setPassword('new@runpass.test', 'RunpassDemo123!');
      expect(gateway.signedIn, true);
      expect(
        (await gateway.request('/beta/status'))['myStatus'],
        'not_admitted',
      );
      await gateway.forgot('new@runpass.test');
      await gateway.reset('new@runpass.test', '123456', 'RunpassChanged123!');
      await gateway.signOut();
      expect(gateway.signedIn, false);
      await gateway.signIn('new@runpass.test', 'RunpassChanged123!');
      expect(gateway.signedIn, true);
    },
  );

  test(
    'demo completes, edits the review and deletes a participation',
    () async {
      final demo = DemoTransport();
      final gateway = demoGateway(demo);
      await gateway.signIn('demo@runpass.test', 'RunpassDemo123!');
      await gateway.request(
        '/me',
        method: 'PUT',
        body: {'displayName': 'Corredor Demo', 'username': 'corredor_demo'},
      );
      await gateway.request(
        '/beta/admissions',
        method: 'POST',
        body: {'birthDate': '1990-01-01', 'declaresAdult': true},
      );

      final catalog = await gateway.request('/editions');
      expect(catalog['items'], hasLength(20));
      final edition = (catalog['items'] as List).first as Map<String, dynamic>;
      var participation = await gateway.request(
        '/participations',
        method: 'POST',
        body: {'editionId': edition['id'], 'distanceId': '5k'},
      );
      final upload = await gateway.uploadImage([
        0xff,
        0xd8,
        0xff,
        0xd9,
      ], 'image/jpeg');
      participation = await gateway.request(
        '/participations/${participation['id']}/complete',
        method: 'POST',
        body: {
          'expectedVersion': participation['version'],
          'declaredCompleted': true,
          'medalImageReference': upload['imageReference'],
          'ratings': {
            'organization': 5,
            'course': 5,
            'hydration': 5,
            'kit': 5,
            'medal': 5,
            'security': 5,
            'accessibility': 5,
            'overall': 5,
          },
          'comment': 'Minha primeira avaliação',
        },
      );
      final reviewPath = '/participations/${participation['id']}/review';
      var review = await gateway.request(reviewPath);
      review = await gateway.request(
        reviewPath,
        method: 'PUT',
        body: {
          'expectedVersion': review['version'],
          'ratings': Map<String, dynamic>.from(review['ratings'] as Map),
        },
      );
      expect(review.containsKey('comment'), false);

      final deletion = await gateway.request(
        '/participations/${participation['id']}',
        method: 'DELETE',
        query: {'expectedVersion': '${participation['version']}'},
      );
      expect(deletion['publiclyHidden'], true);
    },
  );
}
