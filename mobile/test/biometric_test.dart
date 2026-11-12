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
    await tester.tap(find.text('Entrar'));
    // O indicador de "entrando" gira atras do dialogo: nao ha como "assentar".
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Entrar com biometria?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('biometric-yes')));
    await tester.pumpAndSettle();
    expect(await BiometricPrefs.enabled(), isTrue);
    expect(find.byType(RunPassHomeScreen), findsOneWidget);
  });

  testWidgets(
    'e-mail salvo vem preenchido e o rosto entra sem senha so para esse e-mail',
    (tester) async {
      tall(tester);
      SharedPreferences.setMockInitialValues({
        'biometric-lock': true,
        'saved-email': 'eu@x.test',
      });
      final fake = FakeGate();
      biometricGate = fake;
      final store = MemoryTokenStore()..value = 'r1';
      await tester.pumpWidget(
        MaterialApp(
          home: IdentityScreen(gateway: gateway(store), autoRestore: false),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextFormField, 'E-mail');
      expect(tester.widget<TextFormField>(field).controller!.text, 'eu@x.test');
      expect(find.byKey(const Key('biometric-retry')), findsOneWidget);
      expect(fake.asked, 0); // nao dispara sozinho

      await tester.enterText(field, 'outro@x.test');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('biometric-retry')), findsNothing);

      await tester.enterText(field, 'EU@x.test ');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('biometric-retry')));
      await tester.pumpAndSettle();
      expect(fake.asked, 1);
      expect(find.byType(RunPassHomeScreen), findsOneWidget);
    },
  );

  testWidgets(
    'sem token guardado o e-mail vem salvo, mas nao ha botao do rosto',
    (tester) async {
      tall(tester);
      SharedPreferences.setMockInitialValues({
        'biometric-lock': true,
        'saved-email': 'eu@x.test',
      });
      biometricGate = FakeGate();
      await tester.pumpWidget(
        MaterialApp(
          home: IdentityScreen(
            gateway: gateway(MemoryTokenStore()),
            autoRestore: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('biometric-retry')), findsNothing);
    },
  );

  testWidgets('Sair com biometria ligada guarda o token e nao entra sozinho', (
    tester,
  ) async {
    tall(tester);
    SharedPreferences.setMockInitialValues({
      'biometric-lock': true,
      'saved-email': 'eu@x.test',
    });
    biometricGate = FakeGate();
    final store = MemoryTokenStore()..value = 'r1';
    final g = gateway(store);
    expect(await g.restoreSession(), isTrue);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(gateway: g)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('sign-out')));
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    expect(store.value, 'r1'); // token segue no Keychain
    expect(await BiometricPrefs.enabled(), isTrue);
    expect(g.signedIn, isFalse);
    expect(find.text('Entre no MeuPódio'), findsOneWidget);
    expect(find.byKey(const Key('biometric-retry')), findsOneWidget);
  });

  testWidgets('Sair e esquecer apaga token, biometria e e-mail salvo', (
    tester,
  ) async {
    tall(tester);
    SharedPreferences.setMockInitialValues({
      'biometric-lock': true,
      'saved-email': 'eu@x.test',
    });
    biometricGate = FakeGate();
    final store = MemoryTokenStore()..value = 'r1';
    final g = gateway(store);
    expect(await g.restoreSession(), isTrue);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(gateway: g)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('sign-out-forget')));
    await tester.tap(find.byKey(const Key('sign-out-forget')));
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(await BiometricPrefs.enabled(), isFalse);
    expect(await SavedAccount.email(), isNull);
    expect(find.byKey(const Key('biometric-retry')), findsNothing);
  });

  test(
    'sessao trancada: nao pede biometria para checar, vale 7 dias e destranca',
    () async {
      var now = DateTime(2026, 11, 11, 10);
      final store = MemoryTokenStore()..value = 'r1';
      final g = IdentityGateway(
        cognito: Uri.parse('https://cognito.example'),
        api: Uri.parse('https://api.example'),
        clientId: 'synthetic',
        tokenStore: store,
        clock: () => now,
        transport: (uri, method, headers, body) async => const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'a'},
        }),
      );
      await g.lockSession();
      expect(await g.isLocked, isTrue);
      expect(await g.hasStoredSession, isTrue);
      now = now.add(const Duration(days: 6));
      expect(await g.hasStoredSession, isTrue);
      expect(await g.restoreSession(), isTrue); // entrou: destranca
      expect(await g.isLocked, isFalse);
      expect(store.value, 'r1');

      await g.lockSession();
      now = now.add(const Duration(days: 8));
      expect(await g.hasStoredSession, isFalse); // venceu: esquecida
      expect(store.value, isNull);
      expect(await g.restoreSession(), isFalse);
    },
  );

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
