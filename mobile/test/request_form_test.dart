import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/edition_requests.dart';
import 'package:runpass/identity_gateway.dart';

Future<IdentityGateway> gateway() async {
  final g = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await g.signIn('synthetic@example.test', 'synthetic');
  return g;
}

String typed(String raw) => const DateMaskFormatter()
    .formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: raw))
    .text;

void main() {
  test('a máscara coloca as barras: DD/MM/AAAA', () {
    expect(typed('1'), '1');
    expect(typed('140'), '14/0');
    expect(typed('14032027'), '14/03/2027');
    expect(typed('14/03/2027'), '14/03/2027');
    expect(typed('140320271234'), '14/03/2027');
    expect(typed('ab1c4'), '14');
  });

  test('a data vai do formato da tela para o do servidor e volta', () {
    expect(requestDateToIso('14/03/2027'), '2027-03-14');
    expect(requestDateToIso('31/02/2027'), isNull);
    expect(requestDateToIso('2027-03-14'), isNull);
    expect(requestDateToDisplay('2027-03-14'), '14/03/2027');
    expect(requestDateError('14/03/2027'), isNull);
    expect(requestDateError('2027-03-14'), isNotNull);
  });

  testWidgets('o pedido mostra a data sugerida como DD/MM/AAAA', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EditionRequestFormScreen(
          gateway: await gateway(),
          prefill: const {'name': 'Corrida', 'date': '2027-03-14'},
        ),
      ),
    );
    expect(find.text('14/03/2027'), findsOneWidget);
    expect(find.text('Data (DD/MM/AAAA)'), findsOneWidget);
  });

  testWidgets('estado e cidade são escolhidos na roda de rolagem', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: EditionRequestFormScreen(gateway: await gateway())),
    );
    final city = tester.widget<TextFormField>(
      find.byKey(const Key('request-city')),
    );
    expect(city.enabled, isTrue);
    await tester.tap(find.byKey(const Key('request-city')));
    await tester.pumpAndSettle();
    expect(find.text('Estado e cidade'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-done')));
    await tester.pumpAndSettle();
    expect(find.text('São Paulo'), findsOneWidget);
    expect(find.text('SP'), findsOneWidget);
    // Sem teclado: o campo é só de leitura, então digitar não altera o valor.
    await tester.tap(find.byKey(const Key('request-state')));
    await tester.pumpAndSettle();
    expect(find.text('Estado e cidade'), findsOneWidget);
  });
}
