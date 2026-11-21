import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/friends.dart';

/// Foto de perfil em formato de medalha: com o cordão por padrão; sem ele quando fica sobre o banner.
void main() {
  Future<void> show(WidgetTester tester, Widget avatar) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: avatar)),
    ),
  );

  testWidgets('por padrão tem o cordão em cima do círculo dourado', (
    tester,
  ) async {
    await show(tester, const ProfileAvatar(radius: 30));
    expect(find.byKey(const Key('medal-avatar')), findsOneWidget);
    expect(find.byKey(const Key('medal-avatar-ribbon')), findsOneWidget);
  });

  testWidgets('sem cordão fica só o círculo dourado', (tester) async {
    await show(tester, const ProfileAvatar(radius: 46, ribbon: false));
    expect(find.byKey(const Key('medal-avatar')), findsOneWidget);
    expect(find.byKey(const Key('medal-avatar-ribbon')), findsNothing);
  });
}
