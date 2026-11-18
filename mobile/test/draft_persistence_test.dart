import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';

// Dados [FICTICIA]. O rascunho guarda o formulário no aparelho (sobrevive a fechar o app) e a avaliação tem o
// atalho "mesma nota para todos os critérios", em que a nota é escolhida pela pessoa.

Future<IdentityGateway> gateway() async {
  final g = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    sleeper: (_) async {},
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      if (uri.path == '/editions/A') {
        return const JsonReply(200, {
          'id': 'A',
          'name': '[FICTICIA] Corrida',
          'date': '2000-01-01',
          'city': 'São Paulo',
          'state': 'SP',
          'status': 'past',
          'version': 1,
          'distances': [
            {'id': '10k', 'kilometers': 10},
          ],
        });
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await g.signIn('synthetic@example.test', 'synthetic');
  return g;
}

const draft = {
  'id': 'draft-9',
  'editionId': 'A',
  'distanceId': '10k',
  'state': 'draft',
  'version': 1,
};

Future<void> open(WidgetTester tester, IdentityGateway g) async {
  tester.view.physicalSize = const Size(800, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      home: ParticipationDraftScreen(gateway: g, initial: draft),
    ),
  );
  await tester.pumpAndSettle();
}

List<int> ratingValues(WidgetTester tester) => [
  for (final w in tester.widgetList<RatingInput>(find.byType(RatingInput)))
    w.value,
];

void main() {
  testWidgets(
    '"mesma nota para todos": a pessoa escolhe a nota e ela vale para os 8 critérios',
    (tester) async {
      final g = await gateway();
      await open(tester, g);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('same-rating-4')),
        200,
        scrollable: list,
      );
      // Nenhuma nota vem pronta.
      expect(ratingValues(tester).every((v) => v == 0), isTrue);
      await tester.ensureVisible(find.byKey(const Key('same-rating-4')));
      await tester.tap(find.byKey(const Key('same-rating-4')));
      await tester.pumpAndSettle();
      expect(ratingValues(tester), isNotEmpty);
      expect(ratingValues(tester).every((v) => v == 4), isTrue);
      // Dá para ajustar um critério depois.
      final kit = find.byWidgetPredicate(
        (w) => w is RatingInput && w.label == 'Kit',
      );
      await tester.scrollUntilVisible(kit, 100, scrollable: list);
      tester.widget<RatingInput>(kit).onChanged!(2);
      await tester.pump();
      expect(tester.widget<RatingInput>(kit).value, 2);
    },
  );

  testWidgets(
    'rascunho guardado no aparelho: volta com notas, comentário e texto depois de "fechar o app"',
    (tester) async {
      final g = await gateway();
      await open(tester, g);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('same-rating-3')),
        200,
        scrollable: list,
      );
      await tester.ensureVisible(find.byKey(const Key('same-rating-3')));
      await tester.tap(find.byKey(const Key('same-rating-3')));
      await tester.pumpAndSettle();
      final comment = find.widgetWithText(TextField, 'Comentário (opcional)');
      await tester.scrollUntilVisible(comment, 200, scrollable: list);
      await tester.enterText(comment, 'Gostei muito');
      await tester.pump();
      // Sai da tela (o rascunho é guardado) e "fecha o app": a memória do app se perde.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      draftFormCache.clear();
      final stored = await readDraftForm('draft-9');
      expect(stored?['comment'], 'Gostei muito');
      expect((stored?['ratings'] as Map).values.every((v) => v == 3), isTrue);
      // Reabre o rascunho: tudo volta.
      await open(tester, g);
      await tester.scrollUntilVisible(
        find.widgetWithText(TextField, 'Comentário (opcional)'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Comentário (opcional)'),
            )
            .controller!
            .text,
        'Gostei muito',
      );
      expect(ratingValues(tester).every((v) => v == 3), isTrue);
    },
  );

  testWidgets('esquecer o rascunho apaga o que estava guardado', (
    tester,
  ) async {
    await persistDraftForm('draft-x', {'comment': 'oi'});
    expect((await readDraftForm('draft-x'))?['comment'], 'oi');
    await forgetDraftForm('draft-x');
    expect(await readDraftForm('draft-x'), isNull);
  });
}
