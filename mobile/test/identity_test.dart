import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/main.dart';

void main() {
  test('sign-up confirmation and recovery use Cognito, without backend password endpoints', () async {
    final operations = <String>[];
    final gateway = IdentityGateway(
      cognito: Uri.parse('https://cognito.example'),
      api: Uri.parse('https://api.example'),
      clientId: 'synthetic',
      transport: (uri, method, headers, body) async {
        expect(uri.host, 'cognito.example');
        expect(headers.containsKey('Authorization'), false);
        operations.add(headers['X-Amz-Target']!.split('.').last);
        return const JsonReply(200, {});
      },
    );
    await gateway.signUp('synthetic@example.test', 'Synthetic_password1!');
    await gateway.confirm('synthetic@example.test', '123456');
    await gateway.forgot('synthetic@example.test');
    await gateway.reset(
      'synthetic@example.test',
      '123456',
      'New_synthetic_password1!',
    );
    expect(operations, [
      'SignUp',
      'ConfirmSignUp',
      'ForgotPassword',
      'ConfirmForgotPassword',
    ]);
    expect(gateway.signedIn, false);
  });

  test(
    'lost response retry preserves idempotency key and token is cleared on 401',
    () async {
      final keys = <String>[];
      var attempts = 0;
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
          expect(headers['Authorization'], 'Bearer synthetic');
          if (method == 'PUT') {
            keys.add(headers['Idempotency-Key']!);
            if (attempts++ == 0) {
              throw const IdentityIssue('SERVICE_UNAVAILABLE');
            }
            return const JsonReply(201, {'id': 'u1'});
          }
          return const JsonReply(401, {'code': 'INVALID_TOKEN'});
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      final command = {'displayName': 'Runner', 'username': 'runner'};
      await expectLater(
        gateway.request('/me', method: 'PUT', body: command),
        throwsA(isA<IdentityIssue>()),
      );
      await gateway.request('/me', method: 'PUT', body: command);
      expect(keys[0], keys[1]);
      await expectLater(gateway.request('/me'), throwsA(isA<IdentityIssue>()));
      expect(gateway.signedIn, false);
    },
  );

  test('sign-in challenge is not an authenticated session', () async {
    final gateway = IdentityGateway(
      cognito: Uri.parse('https://cognito.example'),
      api: Uri.parse('https://api.example'),
      clientId: 'synthetic',
      transport: (uri, method, headers, body) async => const JsonReply(200, {
        'ChallengeName': 'SOFTWARE_TOKEN_MFA',
        'Session': 'uncompleted',
      }),
    );
    await expectLater(
      gateway.signIn('synthetic@example.test', 'synthetic'),
      throwsA(isA<IdentityIssue>()),
    );
    expect(gateway.signedIn, false);
  });

  test(
    'image upload uses signed headers and finalizes only after byte transfer',
    () async {
      final calls = <String>[];
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
          calls.add('$method ${uri.path}');
          if (uri.path == '/uploads') {
            expect(body, {'contentType': 'image/jpeg', 'sizeBytes': 4});
            return const JsonReply(201, {
              'uploadId': 'upload-1',
              'uploadUrl': 'https://private.example/upload-1',
              'uploadMethod': 'PUT',
              'uploadHeaders': {'Content-Type': 'image/jpeg'},
            });
          }
          if (method == 'POST') {
            return const JsonReply(200, {
              'uploadId': 'upload-1',
              'state': 'pending',
            });
          }
          return const JsonReply(200, {
            'uploadId': 'upload-1',
            'state': 'valid',
            'imageReference': 'img_private',
          });
        },
        byteTransport: (uri, method, headers, bytes) async {
          expect(uri, Uri.parse('https://private.example/upload-1'));
          expect(method, 'PUT');
          expect(headers, {'Content-Type': 'image/jpeg'});
          expect(bytes, [0xff, 0xd8, 0xff, 0xd9]);
          calls.add('PUT signed-object');
          return 200;
        },
        sleeper: (duration) async =>
            expect(duration, const Duration(seconds: 1)),
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      final result = await gateway.uploadImage([
        0xff,
        0xd8,
        0xff,
        0xd9,
      ], 'image/jpeg');
      expect(result['imageReference'], 'img_private');
      expect(calls, [
        'POST /uploads',
        'PUT signed-object',
        'POST /uploads/upload-1/finalize',
        'GET /uploads/upload-1/status',
      ]);
    },
  );

  testWidgets(
    'existing runner signs in and sees admission, without fictitious catalog',
    (tester) async {
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
          if (uri.path == '/me') {
            return const JsonReply(200, {'displayName': 'Corredora'});
          }
          return const JsonReply(200, {
            'myStatus': 'admitted',
            'admissionsOpen': true,
          });
        },
      );
      await tester.pumpWidget(MainApp(gateway: gateway));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'E-mail'),
        'synthetic@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Senha'),
        'Synthetic_password1!',
      );
      await tester.tap(find.text('Entrar no RunPass'));
      await tester.pumpAndSettle();
      // Sem tela intermediaria: quem ja tem cadastro entra direto no app.
      expect(find.byType(RunPassHomeScreen), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Excluir minha conta'), findsNothing);
    },
  );

  testWidgets('unconfigured environment fails closed', (tester) async {
    await tester.pumpWidget(const MainApp());
    expect(
      find.text('O RunPass ainda não está disponível neste ambiente.'),
      findsOneWidget,
    );
    expect(find.byType(TextFormField), findsNothing);
  });
}
