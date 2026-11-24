import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/main.dart';
import 'package:runpass/registration_card.dart';

/// Backend sintetico compartilhado entre varias instancias de gateway, pra
/// simular "fechar e reabrir o app" (gateway novo) sem perder o que ja tinha
/// sido de fato salvo no servidor — exatamente a condicao real que expos os
/// bugs de pular etapa (localizacao) e pular a celebracao (23/11/2026).
class _FakeBackend {
  String? displayName;
  String? username;
  int version = 1;
  String? photoReference;
  String? state;
  String? city;
  String? gender;
  String? birthDate;
  String myStatus = 'not_admitted';
}

IdentityGateway _gatewayFor(_FakeBackend backend) => IdentityGateway(
  cognito: Uri.parse('https://cognito.example'),
  api: Uri.parse('https://api.example'),
  clientId: 'synthetic',
  transport: (uri, method, headers, body) async {
    if (uri.host == 'cognito.example') {
      return const JsonReply(200, {
        'AuthenticationResult': {'AccessToken': 'synthetic'},
      });
    }
    if (uri.path == '/me' && method == 'GET') {
      if (backend.displayName == null) {
        return const JsonReply(404, {'code': 'PROFILE_NOT_FOUND'});
      }
      return JsonReply(200, {
        'id': 'u1',
        'displayName': backend.displayName,
        'username': backend.username,
        'version': backend.version,
        'photoReference': backend.photoReference,
        'state': backend.state,
        'city': backend.city,
        'gender': backend.gender,
        'birthDate': backend.birthDate,
      });
    }
    if (uri.path == '/me' && method == 'PUT') {
      backend.displayName = body!['displayName'] as String;
      backend.username = body['username'] as String;
      backend.version = 1;
      return JsonReply(200, {
        'id': 'u1',
        'displayName': backend.displayName,
        'username': backend.username,
        'version': backend.version,
        'photoReference': backend.photoReference,
        'state': backend.state,
        'city': backend.city,
      });
    }
    if (uri.path == '/me' && method == 'PATCH') {
      final newBody = body!;
      if (newBody.containsKey('state')) {
        backend.state = newBody['state'] as String?;
        backend.city = newBody['city'] as String?;
      }
      if (newBody.containsKey('photoReference')) {
        backend.photoReference = newBody['photoReference'] as String?;
      }
      backend.version += 1;
      return JsonReply(200, {
        'id': 'u1',
        'displayName': backend.displayName,
        'username': backend.username,
        'version': backend.version,
        'photoReference': backend.photoReference,
        'state': backend.state,
        'city': backend.city,
      });
    }
    if (uri.path == '/beta/admissions' && method == 'POST') {
      backend.myStatus = 'admitted';
      backend.gender = body!['gender'] as String?;
      backend.birthDate = body['birthDate'] as String?;
      return const JsonReply(201, {});
    }
    if (uri.path == '/beta/status') {
      return JsonReply(200, {
        'myStatus': backend.myStatus,
        'admissionsOpen': true,
      });
    }
    if (uri.path == '/uploads' && method == 'POST') {
      return const JsonReply(200, {
        'uploadId': 'up1',
        'uploadUrl': 'https://upload.example/up1',
        'uploadMethod': 'PUT',
        'uploadHeaders': <String, String>{},
      });
    }
    if (uri.path.endsWith('/finalize')) {
      backend.photoReference = 'foto-sintetica';
      backend.version += 1;
      return const JsonReply(200, {'state': 'ready'});
    }
    return const JsonReply(200, {'items': []});
  },
);

Future<void> _signUpAndCreateProfile(
  WidgetTester tester,
  IdentityGateway gateway,
) async {
  await tester.ensureVisible(find.text('Criar conta'));
  await tester.tap(find.text('Criar conta'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextFormField, 'E-mail'),
    'nova@runpass.test',
  );
  await tester.ensureVisible(find.text('Continuar'));
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Crie uma senha'),
    'uma-senha-boa-e-forte',
  );
  await tester.ensureVisible(find.text('Continuar'));
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Código recebido'),
    '123456',
  );
  await tester.ensureVisible(find.text('Continuar'));
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
  // Perfil (nome/usuario).
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Nome e sobrenome'),
    'Corredora Teste',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Nome de usuário'),
    'corredora_teste',
  );
  await tester.ensureVisible(find.text('Continuar'));
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
}

Future<void> _fillAdmission(WidgetTester tester) async {
  expect(find.text('Em qual categoria você corre?'), findsOneWidget);
  await tester.ensureVisible(find.text('Feminino'));
  await tester.tap(find.text('Feminino'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('birth-date-field')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('birth-date-done')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byType(CheckboxListTile));
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Continuar'));
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
}

Future<void> _fillLocation(WidgetTester tester) async {
  expect(find.text('Qual a sua cidade?'), findsOneWidget);
  await tester.tap(find.byKey(const Key('location-field')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('location-done')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Continuar'));
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
}

/// Simula "reabrir o app": login manual pela propria UI (nao chamando
/// `gateway.signIn` por fora, que nao dispararia o `resume()` do app).
Future<void> _reopenAndLogIn(
  WidgetTester tester, [
  String email = 'nova@runpass.test',
]) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'E-mail'),
    email,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Senha'),
    'qualquer-coisa',
  );
  await tester.ensureVisible(find.text('Entrar'));
  await tester.tap(find.text('Entrar'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'fecha o app depois da admissão mas antes de escolher a cidade: '
    'reabrir (gateway novo) retoma em "Qual a sua cidade?", não pula pra '
    'foto',
    (tester) async {
      final backend = _FakeBackend();
      final firstGateway = _gatewayFor(backend);
      await tester.pumpWidget(MainApp(gateway: firstGateway));
      await _signUpAndCreateProfile(tester, firstGateway);
      await _fillAdmission(tester);
      // Agora admitido no backend; fecha antes de escolher a cidade.
      expect(backend.myStatus, 'admitted');
      expect(backend.state, isNull);

      // Derruba a arvore de widgets por completo (inclusive o Navigator com
      // chave global) antes de montar o "app reaberto" — senao o Flutter
      // reaproveita o mesmo Navigator preso na rota anterior.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final secondGateway = _gatewayFor(backend);
      await tester.pumpWidget(MainApp(gateway: secondGateway));
      await _reopenAndLogIn(tester);
      expect(find.text('Qual a sua cidade?'), findsOneWidget);
      expect(find.byType(RunPassHomeScreen), findsNothing);

      // A admissao ja foi aceita no servidor: a ficha de inscricao precisa
      // mostrar genero e data de nascimento de novo, lidos do proprio /me
      // (nao ha mais rascunho local pra genero/nascimento depois que a
      // admissao e aceita — ele e apagado de proposito).
      final card = tester.widget<RegistrationCard>(
        find.byType(RegistrationCard),
      );
      expect(card.gender, 'female');
      expect(card.birthDate, isNotNull);
    },
  );

  testWidgets(
    'fecha o app depois de escolher a cidade mas antes da foto/celebração: '
    'reabrir (gateway novo) ainda mostra a celebração ao final, não pula '
    'direto pra Home',
    (tester) async {
      final backend = _FakeBackend();
      final firstGateway = _gatewayFor(backend);
      await tester.pumpWidget(MainApp(gateway: firstGateway));
      await _signUpAndCreateProfile(tester, firstGateway);
      await _fillAdmission(tester);
      await _fillLocation(tester);
      // Location ja salva no backend; fecha antes da tela de foto.
      expect(backend.state, isNotNull);
      expect(backend.photoReference, isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final secondGateway = _gatewayFor(backend);
      await tester.pumpWidget(MainApp(gateway: secondGateway));
      await _reopenAndLogIn(tester);

      // Retoma direto na tela de foto (localizacao ja estava salva), com o
      // botao sempre "Continuar" — nunca "Pular por enquanto".
      expect(find.text('Sua foto de perfil'), findsOneWidget);
      expect(find.text('Pular por enquanto'), findsNothing);
      expect(find.text('Continuar'), findsOneWidget);
      expect(
        find.text('Opcional, foto para ser adicionada depois no menu do perfil'),
        findsOneWidget,
      );

      // Continua sem escolher foto (ela e opcional) — ainda assim passa
      // pela celebracao, nao direto pra Home.
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(find.text('Começar minha jornada'), findsOneWidget);
      expect(find.byType(RunPassHomeScreen), findsNothing);

      await tester.tap(find.text('Começar minha jornada'));
      await tester.pumpAndSettle();
      expect(find.byType(RunPassHomeScreen), findsOneWidget);
    },
  );

  testWidgets(
    'usuário antigo de verdade (poucas edições de perfil, mas já com '
    'localização e foto salvas) não vê a celebração ao restaurar a sessão',
    (tester) async {
      final backend = _FakeBackend()
        ..displayName = 'Quem Já Usa'
        ..username = 'quem_ja_usa'
        ..version = 2
        ..photoReference = 'avatar-antigo'
        ..state = 'RJ'
        ..city = 'Rio de Janeiro'
        ..myStatus = 'admitted';
      final gateway = _gatewayFor(backend);
      await tester.pumpWidget(MainApp(gateway: gateway));
      await _reopenAndLogIn(tester, 'quem-ja-usa@runpass.test');
      expect(find.byType(RunPassHomeScreen), findsOneWidget);
      expect(find.text('Começar minha jornada'), findsNothing);
    },
  );

  testWidgets(
    'fecha o app no meio do preenchimento da admissão (antes de tocar '
    'Continuar): reabrir restaura gênero, data de nascimento e a '
    'declaração de maioridade, sem precisar preencher tudo de novo',
    (tester) async {
      final backend = _FakeBackend();
      final firstGateway = _gatewayFor(backend);
      await tester.pumpWidget(MainApp(gateway: firstGateway));
      await _signUpAndCreateProfile(tester, firstGateway);
      expect(find.text('Em qual categoria você corre?'), findsOneWidget);
      await tester.ensureVisible(find.text('Feminino'));
      await tester.tap(find.text('Feminino'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('birth-date-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('birth-date-done')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      // Fecha sem tocar em "Continuar" — nada disso foi enviado ao backend.
      expect(backend.myStatus, 'not_admitted');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final secondGateway = _gatewayFor(backend);
      await tester.pumpWidget(MainApp(gateway: secondGateway));
      await _reopenAndLogIn(tester);

      // Mesma etapa, e o rascunho local ja preencheu tudo: toca "Continuar"
      // direto, sem escolher nada de novo, e a admissao segue em frente sem
      // pedir nenhum campo.
      expect(find.text('Em qual categoria você corre?'), findsOneWidget);
      await tester.ensureVisible(find.text('Continuar'));
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(backend.myStatus, 'admitted');
      expect(find.text('Qual a sua cidade?'), findsOneWidget);
    },
  );

  testWidgets(
    'escolhe a cidade no seletor mas fecha o app ANTES de tocar em '
    '"Continuar" na tela de localização: reabrir mostra a mesma tela de '
    'novo, não envia a localização sozinho e não pula pra foto (bug real '
    'de 24/11/2026: o rascunho de localização virou gatilho do envio '
    'automático dentro de status(), sem a pessoa nunca confirmar a tela)',
    (tester) async {
      final backend = _FakeBackend();
      final firstGateway = _gatewayFor(backend);
      await tester.pumpWidget(MainApp(gateway: firstGateway));
      await _signUpAndCreateProfile(tester, firstGateway);
      await _fillAdmission(tester);
      expect(find.text('Qual a sua cidade?'), findsOneWidget);

      // Escolhe a cidade no seletor (como o auto-detect por GPS faria em
      // segundo plano), mas NAO toca em "Continuar" — fecha o app aqui.
      await tester.tap(find.byKey(const Key('location-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location-done')));
      await tester.pumpAndSettle();
      expect(backend.state, isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final secondGateway = _gatewayFor(backend);
      await tester.pumpWidget(MainApp(gateway: secondGateway));
      await _reopenAndLogIn(tester);

      // Continua pedindo pra confirmar a cidade — nao envia sozinho, nem
      // pula pra foto.
      expect(find.text('Qual a sua cidade?'), findsOneWidget);
      expect(backend.state, isNull);
      expect(find.text('Sua foto de perfil'), findsNothing);
    },
  );
}
