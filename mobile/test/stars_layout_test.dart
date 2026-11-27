import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/my_races.dart' show Stars;

/// As estrelas não podem estourar a linha em cartão estreito. Dados fictícios [FICTICIA].
void main() {
  testWidgets(
    'em 60 px de largura as estrelas encolhem sem estouro de layout',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Column(children: [Stars(4.5, size: 19)]),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(Stars)).width, lessThanOrEqualTo(60));
    },
  );

  testWidgets('com espaço de sobra ficam no tamanho normal (5 x 19 px)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: Stars(3, size: 19)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Stars)).width, 95);
  });

  testWidgets('dentro de uma linha sem limite de largura também não quebra', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [Stars(5, size: 14), SizedBox(width: 8), Text('há 2 d')],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
