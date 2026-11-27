import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/main.dart';

/// Simula o Cognito real o suficiente para cobrir os pontos onde a pessoa pode
/// fechar o app no meio do cadastro. As regras abaixo nao sao chute: foram
/// conferidas contra o Cognito real do DEV antes de escrever este arquivo
/// (contas sinteticas criadas e apagadas pelo assistente, com autorizacao):
/// - SignUp num e-mail que ja existe (CONFIRMED ou nao): UsernameExistsException.
/// - ResendConfirmationCode: funciona se UNCONFIRMED; InvalidParameterException
///   se ja CONFIRMED (e exatamente essa diferenca que identity_gateway.dart usa
///   pra saber se deve retomar o cadastro ou bloquear).
/// - ForgotPassword: InvalidParameterException se a conta ainda esta
///   UNCONFIRMED; funciona normalmente se CONFIRMED.
/// - InitiateAuth (login) com senha errada: NotAuthorizedException. Com senha
///   certa numa conta UNCONFIRMED: UserNotConfirmedException.
///
/// A senha entra direto no SignUp (desenho atual, 23/11/2026): fechar o app
/// antes de confirmar deixa uma conta UNCONFIRMED ja com a senha de verdade,
/// nunca mais uma conta confirmada sem senha nenhuma.
class _FakeUser {
  String password;
  bool confirmed = false;
  String? confirmationCode;
  String? resetCode;
  _FakeUser(this.password);
}

class _FakeCognito {
  final Map<String, _FakeUser> users = {};
  int _codeCounter = 100000;
  String _nextCode() => (_codeCounter++).toString();

  JsonReply _err(String type) => JsonReply(400, {'__type': type});

  Future<JsonReply> call(
    Uri uri,
    String method,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    final op = headers['X-Amz-Target']!.split('.').last;
    final username = body?['Username'] as String?;
    switch (op) {
      case 'SignUp':
        if (username == null) return _err('InvalidParameterException');
        if (users.containsKey(username)) {
          return _err('UsernameExistsException');
        }
        final created = _FakeUser(body!['Password'] as String)
          ..confirmationCode = _nextCode();
        users[username] = created;
        return const JsonReply(200, {});
      case 'ResendConfirmationCode':
        final u = users[username];
        if (u == null) return _err('UserNotFoundException');
        if (u.confirmed) return _err('InvalidParameterException');
        u.confirmationCode = _nextCode();
        return const JsonReply(200, {});
      case 'ConfirmSignUp':
        final u = users[username];
        if (u == null) return _err('UserNotFoundException');
        // Comportamento real conferido: confirmar de novo uma conta ja
        // confirmada da ExpiredCodeException, nao um erro de "ja confirmado".
        if (u.confirmed) return _err('ExpiredCodeException');
        if (body!['ConfirmationCode'] != u.confirmationCode) {
          return _err('CodeMismatchException');
        }
        u.confirmed = true;
        return const JsonReply(200, {});
      case 'ForgotPassword':
        final u = users[username];
        if (u == null) return _err('UserNotFoundException');
        if (!u.confirmed) return _err('InvalidParameterException');
        u.resetCode = _nextCode();
        return const JsonReply(200, {});
      case 'ConfirmForgotPassword':
        final u = users[username];
        if (u == null) return _err('UserNotFoundException');
        if (body!['ConfirmationCode'] != u.resetCode) {
          return _err('CodeMismatchException');
        }
        u.password = body['Password'] as String;
        u.resetCode = null;
        return const JsonReply(200, {});
      case 'InitiateAuth':
        final params = (body!['AuthParameters'] as Map).cast<String, dynamic>();
        final authUser = params['USERNAME'] as String;
        final password = params['PASSWORD'] as String;
        final u = users[authUser];
        if (u == null || u.password != password) {
          return _err('NotAuthorizedException');
        }
        if (!u.confirmed) return _err('UserNotConfirmedException');
        return JsonReply(200, {
          'AuthenticationResult': {
            'AccessToken': 'token-for-$authUser',
            'RefreshToken': 'refresh-$authUser',
          },
        });
      case 'GlobalSignOut':
        return const JsonReply(200, {});
    }
    return _err('UnknownOperationException');
  }
}

/// Backend ja admitido e com foto: so interessa aqui o que acontece no login/
/// cadastro via Cognito, nao o resto da jornada de admissao.
Future<JsonReply> _readyApi(
  Uri uri,
  String method,
  Map<String, String> headers,
  Map<String, dynamic>? body,
) async {
  if (uri.path == '/me') {
    return const JsonReply(200, {
      'id': 'u1',
      'displayName': 'Corredora Teste',
      'username': 'corredora_teste',
      'version': 10,
      'photoReference': 'avatar-sintetico',
    });
  }
  if (uri.path == '/beta/status') {
    return const JsonReply(200, {
      'myStatus': 'admitted',
      'admissionsOpen': true,
    });
  }
  return const JsonReply(200, {'items': []});
}

IdentityGateway _gatewayFor(_FakeCognito cognito) => IdentityGateway(
  cognito: Uri.parse('https://cognito.example'),
  api: Uri.parse('https://api.example'),
  clientId: 'synthetic',
  transport: (uri, method, headers, body) => uri.host == 'cognito.example'
      ? cognito.call(uri, method, headers, body)
      : _readyApi(uri, method, headers, body),
);

Future<void> _goToSignUp(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Criar conta'));
  await tester.tap(find.text('Criar conta'));
  await tester.pumpAndSettle();
}

Future<void> _typeAndContinue(
  WidgetTester tester,
  String label,
  String value,
) async {
  await tester.enterText(find.widgetWithText(TextFormField, label), value);
  await tester.ensureVisible(find.text('Continuar'));
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
}

/// Da o e-mail e, na proxima tela ("Crie sua senha"), a senha — chega na
/// etapa de confirmar o codigo, na ordem atual do cadastro (e-mail -> senha
/// -> confirmar), sem ainda digitar o codigo.
Future<void> _goToSignUpWithPassword(
  WidgetTester tester,
  String email,
  String password,
) async {
  await _goToSignUp(tester);
  await _typeAndContinue(tester, 'E-mail', email);
  await _typeAndContinue(tester, 'Crie uma senha', password);
}

String _fieldText(WidgetTester tester, String label) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.widgetWithText(TextFormField, label),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

void main() {
  const email = 'interrompido@runpass.test';
  const password = 'uma-senha-boa-e-forte';

  testWidgets('cadastro completo do zero: e-mail, senha (já entra no SignUp) e '
      'código de confirmação — entra direto no app ao final, sem pedir login', (
    tester,
  ) async {
    final cognito = _FakeCognito();
    final gateway = _gatewayFor(cognito);
    await tester.pumpWidget(MainApp(gateway: gateway));
    await _goToSignUpWithPassword(tester, email, password);
    expect(find.text('Confirme seu e-mail'), findsOneWidget);
    await _typeAndContinue(
      tester,
      'Código recebido',
      cognito.users[email]!.confirmationCode!,
    );
    expect(gateway.signedIn, true);
    expect(find.text('Entrar'), findsNothing);
    expect(cognito.users[email]!.password, password);
  });

  testWidgets(
    'fecha o app logo depois de criar a senha (nunca confirma): reabrir e '
    'repetir o e-mail reenvia o código em vez de travar — a senha da '
    'primeira tentativa é a que vale, e o app avisa isso',
    (tester) async {
      final cognito = _FakeCognito();

      // 1a "sessao do app": cria a senha, pede o codigo, fecha sem confirmar.
      final firstGateway = _gatewayFor(cognito);
      await firstGateway.signUp(email, 'Primeira_senha1!');
      expect(firstGateway.resumedSignUp, false);
      expect(cognito.users[email]!.confirmed, false);

      // 2a "sessao" (app reaberto = gateway novo, mesmo "servidor" Cognito).
      // Digita uma senha DIFERENTE desta vez — nao deve valer; a da primeira
      // tentativa e que continua sendo a senha real da conta.
      final gateway = _gatewayFor(cognito);
      await tester.pumpWidget(MainApp(gateway: gateway));
      await _goToSignUpWithPassword(tester, email, 'Segunda_senha2!');

      expect(
        find.textContaining('cadastro não finalizado'),
        findsOneWidget,
        reason: 'precisa avisar que retomou, nao tratar como e-mail novo',
      );
      expect(
        find.textContaining('senha continua sendo a que você já tinha criado'),
        findsOneWidget,
      );
      expect(gateway.resumedSignUp, true);
      expect(cognito.users[email]!.password, 'Primeira_senha1!');

      await _typeAndContinue(
        tester,
        'Código recebido',
        cognito.users[email]!.confirmationCode!,
      );
      // Sem como saber qual das duas senhas digitadas vale: pede login
      // normal em vez de entrar direto (diferente do fluxo sem interrupcao).
      expect(gateway.signedIn, false);
      expect(find.textContaining('E-mail confirmado'), findsOneWidget);
      expect(find.text('Entrar'), findsOneWidget);

      // A senha da primeira tentativa e a que realmente funciona.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'E-mail'),
        email,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Senha'),
        'Primeira_senha1!',
      );
      await tester.ensureVisible(find.text('Entrar'));
      await tester.tap(find.text('Entrar'));
      await tester.pumpAndSettle();
      expect(gateway.signedIn, true);
    },
  );

  testWidgets('cadastro já completo (confirmado antes, com senha de verdade): '
      'repetir com o mesmo e-mail bloqueia com "já existe conta" — toda conta '
      'confirmada agora tem senha de verdade, nada a "retomar" aqui', (
    tester,
  ) async {
    final cognito = _FakeCognito();
    final setup = _gatewayFor(cognito);
    await setup.signUp(email, 'Senha_original1!');
    await setup.confirm(email, cognito.users[email]!.confirmationCode!);
    expect(cognito.users[email]!.confirmed, true);

    final gateway = _gatewayFor(cognito);
    await tester.pumpWidget(MainApp(gateway: gateway));
    await _goToSignUpWithPassword(tester, email, 'Outra_tentativa1!');

    expect(find.textContaining('Já existe uma conta'), findsOneWidget);
    expect(gateway.resumedSignUp, false);
    // A senha digitada agora nunca chega a ser usada; a conta continua
    // com a senha original.
    expect(cognito.users[email]!.password, 'Senha_original1!');

    // Caminho de saida: recuperar senha normalmente.
    await tester.ensureVisible(find.text('Voltar'));
    await tester.tap(find.text('Voltar'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Esqueceu a senha?'));
    await tester.tap(find.text('Esqueceu a senha?'));
    await tester.pumpAndSettle();
    await _typeAndContinue(tester, 'E-mail', email);
    expect(find.text('Defina uma nova senha'), findsOneWidget);
  });

  testWidgets(
    'digita o código antigo por engano, depois de já ter pedido um novo: '
    'erro claro, sem travar o cadastro',
    (tester) async {
      final cognito = _FakeCognito();
      final setup = _gatewayFor(cognito);
      await setup.signUp(email, 'Primeira_senha1!');
      final staleCode = cognito.users[email]!.confirmationCode!;

      final gateway = _gatewayFor(cognito);
      await tester.pumpWidget(MainApp(gateway: gateway));
      await _goToSignUpWithPassword(tester, email, 'Segunda_senha2!');
      final freshCode = cognito.users[email]!.confirmationCode!;
      expect(freshCode, isNot(staleCode));

      await _typeAndContinue(tester, 'Código recebido', staleCode);
      expect(find.textContaining('Confira o código'), findsOneWidget);
      // Continua na tela de confirmacao, com o caminho de reenviar visivel.
      expect(find.text('Reenviar código'), findsOneWidget);

      await _typeAndContinue(tester, 'Código recebido', freshCode);
      expect(gateway.signedIn, false);
      expect(find.text('Entrar'), findsOneWidget);
    },
  );

  testWidgets(
    'tenta entrar direto com a senha errada, numa conta que não existe ou '
    'nunca foi confirmada: mensagem única (não revela se o e-mail existe), '
    'orientando a criar conta',
    (tester) async {
      final gateway = _gatewayFor(_FakeCognito());
      await tester.pumpWidget(MainApp(gateway: gateway));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'E-mail'),
        'ninguem-usou-esse-email@runpass.test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Senha'),
        'qualquer-coisa',
      );
      await tester.ensureVisible(find.text('Entrar'));
      await tester.tap(find.text('Entrar'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'E-mail ou senha incorretos. Se ainda não tem conta, toque em Criar conta.',
        ),
        findsOneWidget,
      );
      expect(gateway.signedIn, false);
    },
  );

  testWidgets(
    'tenta entrar com a senha CERTA numa conta ainda não confirmada: o '
    'login já reenvia o código sozinho e leva direto pra tela de confirmar, '
    'sem a pessoa precisar descobrir isso',
    (tester) async {
      final cognito = _FakeCognito();
      final setup = _gatewayFor(cognito);
      await setup.signUp(email, password);
      final originalCode = cognito.users[email]!.confirmationCode!;

      final gateway = _gatewayFor(cognito);
      await tester.pumpWidget(MainApp(gateway: gateway));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'E-mail'),
        email,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Senha'),
        password,
      );
      await tester.ensureVisible(find.text('Entrar'));
      await tester.tap(find.text('Entrar'));
      await tester.pumpAndSettle();

      expect(find.text('Confirme seu e-mail'), findsOneWidget);
      expect(
        find.text(
          'Confirme seu e-mail. Enviamos um novo código de confirmação.',
        ),
        findsOneWidget,
      );
      // Reenviou de verdade: o codigo mudou, sem a pessoa tocar em nada.
      final newCode = cognito.users[email]!.confirmationCode!;
      expect(newCode, isNot(originalCode));

      await _typeAndContinue(tester, 'Código recebido', newCode);
      expect(gateway.signedIn, true);
    },
  );

  testWidgets('"ver senha" (olho) está disponível na tela de login', (
    tester,
  ) async {
    final gateway = _gatewayFor(_FakeCognito());
    await tester.pumpWidget(MainApp(gateway: gateway));
    expect(find.byIcon(Icons.visibility), findsOneWidget);
  });

  testWidgets(
    '"ver senha" (olho) está disponível na tela de criar senha (logo depois '
    'do e-mail, antes do código)',
    (tester) async {
      final gateway = _gatewayFor(_FakeCognito());
      await tester.pumpWidget(MainApp(gateway: gateway));
      await _goToSignUp(tester);
      await _typeAndContinue(tester, 'E-mail', email);
      expect(find.text('Crie sua senha'), findsOneWidget);
      expect(find.byIcon(Icons.visibility), findsOneWidget);
    },
  );

  testWidgets('"ver senha" (olho) está disponível na tela de redefinir senha '
      '("esqueci minha senha")', (tester) async {
    final cognito = _FakeCognito();
    final setup = _gatewayFor(cognito);
    await setup.signUp(email, 'Senha_original1!');
    await setup.confirm(email, cognito.users[email]!.confirmationCode!);

    final gateway = _gatewayFor(cognito);
    await tester.pumpWidget(MainApp(gateway: gateway));
    await tester.ensureVisible(find.text('Esqueceu a senha?'));
    await tester.tap(find.text('Esqueceu a senha?'));
    await tester.pumpAndSettle();
    await _typeAndContinue(tester, 'E-mail', email);
    expect(find.text('Defina uma nova senha'), findsOneWidget);
    expect(find.byIcon(Icons.visibility), findsOneWidget);
  });

  testWidgets(
    'campo de código recebido nunca mantém o valor de uma tentativa '
    'anterior ao entrar numa tela nova (confirmar e-mail ou redefinir senha)',
    (tester) async {
      final cognito = _FakeCognito();
      final gateway = _gatewayFor(cognito);
      await tester.pumpWidget(MainApp(gateway: gateway));

      // 1a tentativa: codigo errado, fica na tela de confirmar com o valor
      // digitado (isso e esperado — a pessoa pode querer corrigi-lo).
      await _goToSignUpWithPassword(tester, email, password);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Código recebido'),
        '000000',
      );
      await tester.ensureVisible(find.text('Continuar'));
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Confira o código'), findsOneWidget);
      expect(_fieldText(tester, 'Código recebido'), '000000');

      // Volta e comeca de novo com outro e-mail: o codigo da tentativa
      // anterior NAO pode aparecer na nova tela de confirmacao.
      await tester.ensureVisible(find.text('Voltar'));
      await tester.tap(find.text('Voltar'));
      await tester.pumpAndSettle();
      const otherEmail = 'segundo-cadastro@runpass.test';
      await _goToSignUpWithPassword(tester, otherEmail, password);
      expect(find.text('Confirme seu e-mail'), findsOneWidget);
      expect(_fieldText(tester, 'Código recebido'), isEmpty);

      // Confirma de verdade: nenhum resquicio do codigo usado em nenhum campo.
      await _typeAndContinue(
        tester,
        'Código recebido',
        cognito.users[otherEmail]!.confirmationCode!,
      );
      expect(gateway.signedIn, true);
    },
  );

  testWidgets(
    'campo de código recebido também começa vazio na tela de redefinir '
    'senha, pelo caminho de "esqueci minha senha"',
    (tester) async {
      final cognito = _FakeCognito();
      final setup = _gatewayFor(cognito);
      await setup.signUp(email, password);
      await setup.confirm(email, cognito.users[email]!.confirmationCode!);

      final gateway = _gatewayFor(cognito);
      await tester.pumpWidget(MainApp(gateway: gateway));
      await tester.ensureVisible(find.text('Esqueceu a senha?'));
      await tester.tap(find.text('Esqueceu a senha?'));
      await tester.pumpAndSettle();
      await _typeAndContinue(tester, 'E-mail', email);
      expect(find.text('Defina uma nova senha'), findsOneWidget);
      expect(_fieldText(tester, 'Código recebido'), isEmpty);
    },
  );
}
