import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/medal_scan.dart';

/// Corrida que já tem publicação: o aviso com as três escolhas. Dados fictícios [FICTICIA].
void main() {
  Future<String?> open(WidgetTester tester, String tap) async {
    String? result = 'não respondeu';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await askRaceHasPost(
              context,
              'Corrida Teste [FICTICIA]',
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('race-has-post-dialog')), findsOneWidget);
    expect(find.text('Esta corrida já tem publicação'), findsOneWidget);
    await tester.tap(find.byKey(Key('race-has-post-$tap')));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('alterar as fotos devolve photos', (tester) async {
    expect(await open(tester, 'photos'), 'photos');
  });

  testWidgets('escolher outra corrida devolve other', (tester) async {
    expect(await open(tester, 'other'), 'other');
  });

  testWidgets('sair devolve exit', (tester) async {
    expect(await open(tester, 'exit'), 'exit');
  });
}
