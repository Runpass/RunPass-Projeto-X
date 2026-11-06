import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/biometrics.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/main.dart';
import 'package:runpass/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeGate implements BiometricGate {
  bool isAvailable, accepts;
  int asked = 0;
  FakeGate({this.isAvailable = true, this.accepts = true});
  @override
  Future<bool> available() async => isAvailable;
  @override
  Future<bool> authenticate(String reason) async {
    asked++;
    return accepts;
  }
}

IdentityGateway gateway(MemoryTokenStore store) => IdentityGateway(
  cognito: Uri.parse('https://cognito.example'),
  api: Uri.parse('https://api.example'),
  clientId: 'synthetic',
  tokenStore: store,
  transport: (uri, method, headers, body) async {
    if (uri.host == 'cognito.example') {
      return const JsonReply(200, {
        'AuthenticationResult': {'AccessToken': 'a', 'RefreshToken': 'r1'},
      });
    }
    if (uri.path == '/me') {
      return const JsonReply(200, {
        'id': 'u',
        'displayName': 'Eu',
        'username': 'eu',
        'version': 3,
        'photoReference': 'img',
      });
    }
    if (uri.path == '/beta/status') {
      return const JsonReply(200, {
        'myStatus': 'admitted',
        'admissionsOpen': true,
      });
    }
    return const JsonReply(200, {'items': []});
  },
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  tearDown(() => biometricGate = DeviceBiometricGate());

  testWidgets('trava ligada: pede biometria antes de renovar a sessao', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'biometric-lock': true});
    final fake = FakeGate();
    biometricGate = fake;
    final store = MemoryTokenStore()..value = 'r1';
    await tester.runAsync(() async {});
    await tester.pumpWidget(MainApp(gateway: gateway(store)));
    await tester.pumpAndSettle();
    expect(fake.asked, 1);
    expect(find.byType(RunPassHomeScreen), findsOneWidget);
  });

  testWidgets('biometria negada cai na senha e oferece tentar de novo', (
    tester,
  ) async {
    tall(tester);
    SharedPreferences.setMockInitialValues({'biometric-lock': true});
    final fake = FakeGate(accepts: false);
    biometricGate = fake;
    final store = MemoryTokenStore()..value = 'r1';
    await tester.pumpWidget(MainApp(gateway: gateway(store)));
    await tester.pumpAndSettle();
    expect(find.byType(RunPassHomeScreen), findsNothing);
    expect(find.byKey(const Key('biometric-retry')), findsOneWidget);
    expect(find.byType(TextFormField), findsWidgets); // senha continua possivel
    expect(store.value, 'r1'); // sessao guardada nao foi apagada
    fake.accepts = true;
    await tester.tap(find.byKey(const Key('biometric-retry')));
    await tester.pumpAndSettle();
    expect(find.byType(RunPassHomeScreen), findsOneWidget);
  });

  testWidgets('sem a trava ligada a sessao guardada entra direto', (
    tester,
  ) async {
    final fake = FakeGate();
    biometricGate = fake;
    final store = MemoryTokenStore()..value = 'r1';
    await tester.pumpWidget(MainApp(gateway: gateway(store)));
    await tester.pumpAndSettle();
    expect(fake.asked, 0);
    expect(find.byType(RunPassHomeScreen), findsOneWidget);
  });

  testWidgets('depois do primeiro login oferece ativar e grava a escolha', (
    tester,
  ) async {
    tall(tester);
    final fake = FakeGate();
    biometricGate = fake;
    final store = MemoryTokenStore();
    await tester.pumpWidget(MainApp(gateway: gateway(store)));
    await tester.pumpAndSettle(); // tenta restaurar a sessao: nao ha nenhuma
    await tester.enterText(
      find.widgetWithText(TextFormField, 'E-mail'),
      'a@x.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Senha'),
      'Senha_forte_1!',
    );
    await tester.tap(find.text('Entrar no RunPass'));
    // O indicador de "entrando" gira atras do dialogo: nao ha como "assentar".
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Entrar com biometria?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('biometric-yes')));
    await tester.pumpAndSettle();
    expect(await BiometricPrefs.enabled(), isTrue);
    expect(find.byType(RunPassHomeScreen), findsOneWidget);
  });

  testWidgets('aparelho sem biometria nao mostra oferta nem chave', (
    tester,
  ) async {
    biometricGate = FakeGate(isAvailable: false);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(gateway: gateway(MemoryTokenStore()))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('biometric-switch')), findsNothing);
  });

  testWidgets('chave nas configuracoes confirma com a biometria', (
    tester,
  ) async {
    final fake = FakeGate();
    biometricGate = fake;
    final g = gateway(MemoryTokenStore());
    await g.signIn('a@x.test', 's');
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(gateway: g)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('biometric-switch')));
    await tester.pumpAndSettle();
    expect(fake.asked, 1);
    expect(await BiometricPrefs.enabled(), isTrue);
    // Negada: nao liga.
    await BiometricPrefs.setEnabled(false);
    fake.accepts = false;
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(gateway: g)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('biometric-switch')));
    await tester.pumpAndSettle();
    expect(await BiometricPrefs.enabled(), isFalse);
  });
}
