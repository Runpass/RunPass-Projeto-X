import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/tagged_people.dart';

/// Ícone de marcar com a foto de quem foi marcado. Dados fictícios [FICTICIA].
void main() {
  IdentityGateway gateway() => IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    transport: (uri, method, headers, body) async => const JsonReply(200, {}),
  );

  Map<String, dynamic> person(String n) => {
    'id': 'p$n',
    'username': 'amigo$n',
    'displayName': 'Amigo $n [FICTICIA]',
  };

  testWidgets('mostra a foto de ate 3 marcados e o numero a mais', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaggedLink(
            gateway: gateway(),
            postId: 'post1',
            tagged: [
              for (final n in ['1', '2', '3', '4']) person(n),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('post-tagged-faces-post1')), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    // Nenhuma foto de marcado sem a pessoa tocar: o ícone de marcar nao existe mais.
    expect(find.byIcon(Icons.local_offer_outlined), findsNothing);
  });

  testWidgets('sem marcados, nao mostra fotos', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaggedLink(
            gateway: gateway(),
            postId: 'post2',
            tagged: const [],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('post-tagged-faces-post2')), findsNothing);
  });
}
