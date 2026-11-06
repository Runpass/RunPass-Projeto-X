import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> item(String id, String at, {bool unread = true}) => {
  'id': id,
  'kind': 'like',
  'createdAt': at,
  'unread': unread,
  'actor': {'id': 'b', 'displayName': 'Bia'},
};

void main() {
  late List<String> shown;
  Future<void> present(
    int id,
    String body, {
    String? payload,
    bool request = false,
  }) async => shown.add(request ? '$body|$payload' : body);
  setUp(() => shown = []);

  test('conta sem historico: o primeiro aviso real NAO e engolido como ponto de partida', () async {
    // 1a checagem, lista vazia: so marca o ponto de partida.
    await LocalAlerts.announce([], present: present);
    expect(shown, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getString('os-alerts-last'),
      '',
    );
    // 2a checagem: chegou o primeiro aviso da vida da conta -> aparece no celular.
    await LocalAlerts.announce([
      item('like:b:p1:2026-11-06T10:00:00Z', '2026-11-06T10:00:00Z'),
    ], present: present);
    expect(shown, ['Bia curtiu sua publicação.']);
    // Mesma lista de novo: nao repete.
    await LocalAlerts.announce([
      item('like:b:p1:2026-11-06T10:00:00Z', '2026-11-06T10:00:00Z'),
    ], present: present);
    expect(shown, hasLength(1));
  });

  test(
    'conta com historico: o historico nao e despejado, so o que chega depois',
    () async {
      await LocalAlerts.announce([
        item('a', '2026-11-05T10:00:00Z'),
        item('b', '2026-11-05T11:00:00Z'),
      ], present: present);
      expect(shown, isEmpty);
      await LocalAlerts.announce([
        item('c', '2026-11-06T09:00:00Z'),
        item('a', '2026-11-05T10:00:00Z'),
      ], present: present);
      expect(shown, hasLength(1));
    },
  );

  test('aviso ja lido ou chave desligada nao aparece', () async {
    await LocalAlerts.announce([], present: present);
    await LocalAlerts.announce([
      item('x', '2026-11-06T09:00:00Z', unread: false),
    ], present: present);
    expect(shown, isEmpty);
    SharedPreferences.setMockInitialValues({'os-alerts-enabled': false});
    await LocalAlerts.announce([
      item('y', '2026-11-06T10:00:00Z'),
    ], present: present);
    expect(shown, isEmpty);
  });

  testWidgets('configuracoes mostram a permissao e os dois testes de aviso', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: OsAlertsSwitch())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('os-alerts-status')), findsOneWidget);
    expect(find.byKey(const Key('os-alerts-test-now')), findsOneWidget);
    expect(find.byKey(const Key('os-alerts-test-later')), findsOneWidget);
  });

  test(
    'pedido para seguir vai ao celular com botoes e o id de quem pediu',
    () async {
      await LocalAlerts.announce([], present: present);
      await LocalAlerts.announce([
        {
          'id': 'follow_request:b::x',
          'kind': 'follow_request',
          'createdAt': '2026-11-06T10:00:00Z',
          'unread': true,
          'actor': {'id': 'b', 'displayName': 'Bia'},
        },
      ], present: present);
      expect(shown.single, startsWith('Bia quer seguir você.|'));
      expect(shown.single, contains('"actorId":"b"'));
    },
  );

  group('botoes Aceitar e Recusar no aviso do celular', () {
    Future<(IdentityGateway, List<String>)> signed() async {
      final calls = <String>[];
      final gateway = IdentityGateway(
        cognito: Uri.parse('https://cognito.example'),
        api: Uri.parse('https://api.example'),
        clientId: 'synthetic',
        transport: (uri, method, headers, body) async {
          if (uri.host == 'cognito.example') {
            return const JsonReply(200, {
              'AuthenticationResult': {'AccessToken': 'a'},
            });
          }
          calls.add('$method ${uri.path}');
          return const JsonReply(200, {'items': [], 'unreadCount': 0});
        },
      );
      await gateway.signIn('a@x.test', 's');
      return (gateway, calls);
    }

    NotificationResponse tap(String? action, [String actor = 'b']) =>
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: action,
          payload: '{"kind":"follow_request","actorId":"$actor"}',
        );

    test('Aceitar chama PUT e Recusar chama DELETE', () async {
      NotificationCenter.active = true;
      addTearDown(() {
        NotificationCenter.active = false;
        NotificationCenter.instance.stop();
      });
      final (gateway, calls) = await signed();
      NotificationCenter.instance.start(gateway);
      await NotificationCenter.instance.handleResponse(tap('accept', 'bia'));
      await NotificationCenter.instance.handleResponse(tap('decline', 'caio'));
      expect(calls, contains('PUT /me/follow-requests/bia'));
      expect(calls, contains('DELETE /me/follow-requests/caio'));
    });

    test('toque no corpo do aviso (sem botao) nao decide nada', () async {
      NotificationCenter.active = true;
      addTearDown(() {
        NotificationCenter.active = false;
        NotificationCenter.instance.stop();
      });
      final (gateway, calls) = await signed();
      NotificationCenter.instance.start(gateway);
      await NotificationCenter.instance.handleResponse(tap(null));
      expect(calls.where((c) => c.contains('follow-requests')), isEmpty);
    });

    test(
      'app abrindo pelo botao: a decisao espera a sessao e depois e aplicada',
      () async {
        NotificationCenter.active = true;
        addTearDown(() {
          NotificationCenter.active = false;
          NotificationCenter.instance.stop();
        });
        // Ainda sem sessao: nada e enviado.
        await NotificationCenter.instance.handleResponse(tap('accept', 'dora'));
        final (gateway, calls) = await signed();
        NotificationCenter.instance.start(gateway);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(calls, contains('PUT /me/follow-requests/dora'));
      },
    );
  });
}
