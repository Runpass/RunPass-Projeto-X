import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/post_stats.dart';

void main() {
  Future<void> show(WidgetTester tester, PostStats stats) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: stats),
      ),
    ),
  );

  testWidgets('sem nenhum número: os três ícones aparecem, cada um com "--"', (
    tester,
  ) async {
    await show(tester, const PostStats());
    expect(find.byIcon(statDistanceIcon), findsOneWidget);
    expect(find.byIcon(statTimeIcon), findsOneWidget);
    expect(find.byIcon(statPaceIcon), findsOneWidget);
    expect(find.text(statEmpty), findsNWidgets(3));
    expect(find.text('Distância'), findsOneWidget);
    expect(find.text('Tempo'), findsOneWidget);
    expect(find.text('Pace'), findsOneWidget);
    // Colocação só quando existe.
    expect(find.byKey(const Key('post-stat-placement')), findsNothing);
  });

  testWidgets('com números: mostra o que veio e "--" só no que falta', (
    tester,
  ) async {
    await show(tester, const PostStats(distance: '10 km', time: '58:23'));
    expect(find.text('10 km'), findsOneWidget);
    expect(find.text('58:23'), findsOneWidget);
    expect(find.text(statEmpty), findsOneWidget); // o pace
    expect(find.byIcon(statPaceIcon), findsOneWidget);
  });

  testWidgets('colocação aparece como quarto item quando informada', (
    tester,
  ) async {
    await show(
      tester,
      const PostStats(
        distance: '5 km',
        time: '25:00',
        pace: '5:00/km',
        placement: '12º',
      ),
    );
    expect(find.byKey(const Key('post-stat-placement')), findsOneWidget);
    expect(find.text('12º'), findsOneWidget);
    expect(find.text(statEmpty), findsNothing);
  });
}
