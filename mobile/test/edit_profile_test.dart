import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/edit_profile.dart';
import 'package:runpass/identity_gateway.dart';

Future<(IdentityGateway, List<Map<String, dynamic>?>)> setup({
  int patchStatus = 200,
  String patchCode = 'X',
}) async {
  final patches = <Map<String, dynamic>?>[];
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
      if (uri.path == '/me' && method == 'PATCH') {
        patches.add(body);
        return patchStatus == 200
            ? const JsonReply(200, {'id': 'u1'})
            : JsonReply(patchStatus, {'code': patchCode});
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return (gateway, patches);
}

const profile = {
  'id': 'u1',
  'version': 4,
  'displayName': 'Corredor Teste',
  'username': 'corredor_teste',
  'bio': 'Antes da frase',
  'birthDate': '1990-03-10',
};

Future<void> open(
  WidgetTester tester,
  IdentityGateway gateway, {
  BirthDatePicker? picker,
}) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          key: const Key('go'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<bool>(
              builder: (_) => EditProfileScreen(
                gateway: gateway,
                profile: profile,
                birthDatePicker: picker ?? pickBirthDateByScroll,
              ),
            ),
          ),
          child: const Text('abrir'),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('go')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('abre com nome, idade/nascimento e frase atuais', (tester) async {
    final (gateway, _) = await setup();
    await open(tester, gateway);
    expect(find.widgetWithText(TextField, 'Corredor Teste'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Antes da frase'), findsOneWidget);
    expect(find.textContaining('10/03/1990'), findsOneWidget);
    expect(find.textContaining('anos'), findsOneWidget);
  });

  testWidgets('salva só o que mudou: nome, nascimento e frase', (tester) async {
    final (gateway, patches) = await setup();
    await open(
      tester,
      gateway,
      picker: (context, initial) async => DateTime(1988, 7, 2),
    );
    await tester.enterText(find.byKey(const Key('edit-name')), 'Novo Nome');
    await tester.enterText(
      find.byKey(const Key('edit-phrase')),
      'Correr é viver',
    );
    await tester.tap(find.byKey(const Key('edit-birth')));
    await tester.pumpAndSettle();
    expect(find.textContaining('02/07/1988'), findsOneWidget);
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(patches, [
      {
        'expectedVersion': 4,
        'displayName': 'Novo Nome',
        'bio': 'Correr é viver',
        'birthDate': '1988-07-02',
      },
    ]);
  });

  testWidgets('sem mudanças não chama o servidor; frase vazia limpa a frase', (
    tester,
  ) async {
    final (gateway, patches) = await setup();
    await open(tester, gateway);
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(patches, isEmpty);

    final (g2, patches2) = await setup();
    await open(tester, g2);
    await tester.enterText(find.byKey(const Key('edit-phrase')), '');
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(patches2, [
      {'expectedVersion': 4, 'bio': null},
    ]);
  });

  testWidgets(
    'nome vazio é recusado antes de enviar; menor de 13 mostra o motivo',
    (tester) async {
      final (gateway, patches) = await setup(
        patchStatus: 422,
        patchCode: 'NOT_ELIGIBLE',
      );
      await open(
        tester,
        gateway,
        picker: (context, initial) async => DateTime(2020, 1, 1),
      );
      await tester.enterText(find.byKey(const Key('edit-name')), '  ');
      await tester.tap(find.byKey(const Key('edit-save')));
      await tester.pumpAndSettle();
      expect(find.text('Informe seu nome.'), findsOneWidget);
      expect(patches, isEmpty);

      await tester.enterText(
        find.byKey(const Key('edit-name')),
        'Corredor Teste',
      );
      await tester.tap(find.byKey(const Key('edit-birth')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-error')), findsOneWidget);
      expect(find.textContaining('13 anos'), findsOneWidget);
      expect(patches.single!['birthDate'], '2020-01-01');
    },
  );
}
