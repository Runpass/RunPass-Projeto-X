import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/main.dart';

/// Regressao: o passo "De onde você é?" do cadastro roda antes da admissao, mas
/// PATCH /me (que salva estado/cidade) exige conta admitida no backend
/// (BETA_ADMISSION_REQUIRED). O app precisa guardar a escolha e so enviar depois
/// que a admissao for concluida (ver status() em main.dart), nunca durante o
/// passo de localizacao em si.
void main() {
  testWidgets(
    'cadastro novo: estado/cidade so vai ao servidor depois da admissao',
    (tester) async {
      var profileCreated = false;
      var admitted = false;
      var version = 1;
      String? savedState, savedCity;
      final patchesWhileLocked = <Map<String, dynamic>?>[];
      final patchesAfterAdmission = <Map<String, dynamic>?>[];

      final gateway = IdentityGateway(
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
            if (!profileCreated) {
              return const JsonReply(404, {'code': 'PROFILE_NOT_FOUND'});
            }
            return JsonReply(200, {
              'id': 'u1',
              'displayName': 'Corredora Teste',
              'username': 'corredora_teste',
              'version': version,
              // Ja com foto: este teste nao cobre o passo de upload, so a ordem
              // localizacao/admissao.
              'photoReference': 'avatar-sintetico',
              'state': savedState,
              'city': savedCity,
            });
          }
          if (uri.path == '/me' && method == 'PUT') {
            profileCreated = true;
            return JsonReply(200, {
              'id': 'u1',
              'displayName': 'Corredora Teste',
              'username': 'corredora_teste',
              'version': version,
              'photoReference': 'avatar-sintetico',
            });
          }
          if (uri.path == '/me' && method == 'PATCH') {
            final isLocation = body != null && body.containsKey('state');
            if (isLocation && !admitted) {
              // Reproduz o bug real: o backend recusa PATCH /me antes da admissao.
              patchesWhileLocked.add(body);
              return const JsonReply(403, {'code': 'BETA_ADMISSION_REQUIRED'});
            }
            if (isLocation) {
              patchesAfterAdmission.add(body);
              savedState = body['state'] as String?;
              savedCity = body['city'] as String?;
            }
            version += 1;
            return JsonReply(200, {
              'id': 'u1',
              'displayName': 'Corredora Teste',
              'username': 'corredora_teste',
              'version': version,
              'photoReference': 'avatar-sintetico',
              'state': savedState,
              'city': savedCity,
            });
          }
          if (uri.path == '/beta/admissions' && method == 'POST') {
            admitted = true;
            return const JsonReply(201, {});
          }
          if (uri.path == '/beta/status') {
            return JsonReply(200, {
              'myStatus': admitted ? 'admitted' : 'not_admitted',
              'admissionsOpen': true,
            });
          }
          return const JsonReply(200, {'items': []});
        },
      );

      await tester.pumpWidget(MainApp(gateway: gateway));

      // Entra no cadastro (Step.signUp -> confirm -> setPassword), ate chegar no
      // perfil, igual a um usuario novo de verdade.
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
        find.widgetWithText(TextFormField, 'Código recebido'),
        '123456',
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

      // Perfil (nome/usuario).
      expect(find.text('Seu perfil de corredor'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome de exibição'),
        'Corredora Teste',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome de usuário'),
        'corredora_teste',
      );
      await tester.ensureVisible(find.text('Continuar'));
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();

      // Localizacao: escolhe estado/cidade e avanca. Isto NAO deve chamar
      // PATCH /me ainda (a conta nao foi admitida).
      expect(find.text('De onde você é?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('location-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location-done')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Continuar'));
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(
        patchesWhileLocked,
        isEmpty,
        reason: 'PATCH /me nao deve ser chamado para estado/cidade antes da admissao',
      );
      expect(savedState, isNull);

      // Admissao (data de nascimento + declaracao de maioridade).
      expect(find.text('Qual a sua idade?'), findsOneWidget);
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

      // So agora, depois da admissao, o estado/cidade escolhidos sao enviados.
      expect(patchesWhileLocked, isEmpty);
      expect(patchesAfterAdmission, hasLength(1));
      expect(savedState, isNotNull);
      expect(savedCity, isNotNull);
    },
  );
}
