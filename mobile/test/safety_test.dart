import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/edition_requests.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/my_races.dart' show distanceLabel;
import 'package:runpass/safety.dart';

/// Denunciar, bloquear, pessoas bloqueadas, links legais e rótulos de distância. Dados fictícios [FICTICIA].
void main() {
  late List<(String, String, Object?)> calls;
  var blocks = <Map<String, dynamic>>[];

  Future<IdentityGateway> setup({String? failReport}) async {
    calls = [];
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
        calls.add((method, uri.path, body));
        if (uri.path == '/reports') {
          return failReport == null
              ? const JsonReply(201, {'id': 'r1', 'received': true})
              : JsonReply(429, {'code': failReport});
        }
        if (uri.path == '/profiles/ana/block') {
          if (method == 'DELETE') blocks = [];
          return const JsonReply(200, {'id': 'ana', 'blocked': true});
        }
        if (uri.path == '/me/blocks') return JsonReply(200, {'items': blocks});
        return const JsonReply(200, {});
      },
    );
    await gateway.signIn('synthetic@example.test', 'synthetic');
    return gateway;
  }

  Future<void> open(
    WidgetTester tester,
    Future<void> Function(BuildContext) go,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => go(context),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('denunciar exige o motivo, envia, agradece e oferece bloquear', (
    tester,
  ) async {
    final gateway = await setup();
    await open(
      tester,
      (c) => reportContent(
        c,
        gateway,
        targetType: 'post',
        targetId: 'p1',
        blockUserId: 'ana',
        blockUserName: 'Ana [FICTICIA]',
      ),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('report-send')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('report-reason-offensive')));
    await tester.enterText(
      find.byKey(const Key('report-text')),
      '  xingou [FICTICIA]  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('report-send')));
    await tester.pumpAndSettle();
    expect(calls.first.$2, '/reports');
    expect(calls.first.$3, {
      'targetType': 'post',
      'targetId': 'p1',
      'reason': 'offensive',
      'text': 'xingou [FICTICIA]',
    });
    expect(find.textContaining('Denúncia enviada'), findsOneWidget);
    // Oferece bloquear em seguida.
    expect(find.text('Bloquear também?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('block-confirm')));
    await tester.pumpAndSettle();
    expect(calls.last.$1, 'PUT');
    expect(calls.last.$2, '/profiles/ana/block');
  });

  testWidgets(
    'limite diário de denúncias mostra aviso claro e não oferece bloquear',
    (tester) async {
      final gateway = await setup(failReport: 'REPORT_LIMIT_REACHED');
      await open(
        tester,
        (c) => reportContent(
          c,
          gateway,
          targetType: 'user',
          targetId: 'ana',
          blockUserId: 'ana',
        ),
      );
      await tester.tap(find.byKey(const Key('report-reason-spam')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('report-send')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('máximo de denúncias de hoje'),
        findsOneWidget,
      );
      expect(find.text('Bloquear também?'), findsNothing);
    },
  );

  testWidgets('Pessoas bloqueadas lista e desbloqueia', (tester) async {
    final gateway = await setup();
    blocks = [
      {'id': 'ana', 'displayName': 'Ana [FICTICIA]', 'username': 'ana_runs'},
      {'id': 'x', 'displayName': 'Usuário removido', 'removed': true},
    ];
    await tester.pumpWidget(
      MaterialApp(home: BlockedPeopleScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ana [FICTICIA]'), findsOneWidget);
    expect(find.text('Usuário removido'), findsOneWidget);
    await tester.tap(find.byKey(const Key('unblock-ana')));
    await tester.pumpAndSettle();
    expect(
      calls.any((c) => c.$1 == 'DELETE' && c.$2 == '/profiles/ana/block'),
      isTrue,
    );
    expect(find.byKey(const Key('blocked-ana')), findsNothing);
    expect(find.byKey(const Key('blocked-x')), findsOneWidget);
  });

  testWidgets('link legal sem endereço configurado avisa em vez de abrir', (
    tester,
  ) async {
    await open(
      tester,
      (c) => openLegalPage(c, '', name: 'A política de privacidade'),
    );
    expect(
      find.textContaining(
        'A política de privacidade ainda não está disponível',
      ),
      findsOneWidget,
    );
  });

  testWidgets('link legal só aceita https', (tester) async {
    await open(
      tester,
      (c) =>
          openLegalPage(c, 'http://exemplo.test/x', name: 'Os termos de uso'),
    );
    expect(
      find.textContaining('Os termos de uso ainda não está disponível'),
      findsOneWidget,
    );
  });

  test('rótulo de distância não arredonda para inteiro', () {
    expect(distanceLabel(5), '5K');
    expect(distanceLabel(10), '10K');
    expect(distanceLabel(10.5), '10,5K');
    expect(distanceLabel(7.54), '7,5K');
    expect(distanceLabel(21.0975), '21K');
    expect(distanceLabel(42.195), '42K');
    expect(distanceLabel(100), '100K');
  });

  test(
    'distância com mais de 4 casas decimais é recusada com mensagem clara',
    () {
      expect(requestDistanceError('21,0975'), isNull);
      expect(requestDistanceError('10'), isNull);
      expect(requestDistanceError('10,12345'), contains('4 casas'));
      expect(requestDistanceError('0'), contains('Informe a distância'));
      expect(kmHasTooManyDecimals('5.00001'), isTrue);
      expect(kmHasTooManyDecimals('5.0001'), isFalse);
      expect(kmHasTooManyDecimals('5'), isFalse);
    },
  );
}
