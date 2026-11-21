import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/feedback_screen.dart';
import 'package:runpass/identity_gateway.dart';

/// Tela "Enviar feedback". Dados fictícios [FICTICIA].
void main() {
  Future<(IdentityGateway, List<Object?>)> setup({int status = 201}) async {
    final sent = <Object?>[];
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
        if (uri.path == '/feedback' && method == 'POST') {
          sent.add(body);
          return status == 201
              ? const JsonReply(201, {'id': 'f1', 'received': true})
              : JsonReply(status, {'code': 'FEEDBACK_LIMIT_REACHED'});
        }
        return const JsonReply(200, {});
      },
    );
    await gateway.signIn('synthetic@example.test', 'synthetic');
    return (gateway, sent);
  }

  Future<void> open(WidgetTester tester, IdentityGateway gateway) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FeedbackScreen(gateway: gateway),
                ),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('envia o tipo escolhido e o texto, agradece e volta', (
    tester,
  ) async {
    final (gateway, sent) = await setup();
    await open(tester, gateway);
    await tester.tap(find.byKey(const Key('feedback-kind-problem')));
    await tester.enterText(
      find.byKey(const Key('feedback-text')),
      '  A foto não abriu [FICTICIA]  ',
    );
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pumpAndSettle();
    expect(sent, [
      {'kind': 'problem', 'text': 'A foto não abriu [FICTICIA]'},
    ]);
    expect(find.byType(FeedbackScreen), findsNothing);
    expect(find.textContaining('Feedback enviado'), findsOneWidget);
  });

  testWidgets('sem texto não envia; limite do dia avisa e mantém o texto', (
    tester,
  ) async {
    final (gateway, sent) = await setup(status: 429);
    await open(tester, gateway);
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pump();
    expect(sent, isEmpty);
    expect(find.textContaining('Escreva a sua mensagem'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('feedback-text')), 'Ideia');
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    expect(find.textContaining('máximo de feedbacks de hoje'), findsOneWidget);
    expect(find.text('Ideia'), findsOneWidget);
  });
}
