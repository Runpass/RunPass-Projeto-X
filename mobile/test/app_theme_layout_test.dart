import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/duration_field.dart';
import 'package:runpass/post_preview.dart';
import 'package:runpass/runpass_theme.dart';

/// Telas montadas com o tema real do app. O tema pede largura total nos botões cheios, e um botão
/// assim dentro de uma linha quebra o layout; com `MaterialApp` sem tema o defeito não aparece.
void main() {
  for (final (name, theme) in [
    ('claro', runPassTheme()),
    ('escuro', runPassDarkTheme()),
  ]) {
    testWidgets('seletor de tempo abre e confirma com o tema $name', (
      tester,
    ) async {
      final controller = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(body: DurationField(controller: controller)),
        ),
      );
      await tester.tap(find.byKey(const Key('time-field')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('duration-picker')), findsOneWidget);
      await tester.tap(find.byKey(const Key('duration-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('duration-picker')), findsNothing);
    });
  }

  testWidgets(
    'prévia segue o cartão do Início: corrida acima da foto, sem "concluiu"',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: runPassTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => confirmPostPreview(
                  context,
                  const PostPreviewData(
                    authorName: 'Ana',
                    username: 'ana',
                    raceName: 'Corrida Teste',
                    distance: '10 km',
                    time: '58:23',
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
      expect(tester.takeException(), isNull);
      expect(find.textContaining('concluiu'), findsNothing);
      expect(find.text('@ana'), findsOneWidget);
      expect(find.text('Corrida Teste'), findsOneWidget);
      final race = tester.getTopLeft(
        find.byKey(const Key('post-preview-race')),
      );
      final details = tester.getTopLeft(
        find.byKey(const Key('post-preview-stats')),
      );
      expect(race.dy, lessThan(details.dy));
    },
  );
}
