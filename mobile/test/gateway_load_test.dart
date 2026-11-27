import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';

/// Gateway já autenticado; a API é o `api` recebido. As esperas entre tentativas ficam registradas.
Future<(IdentityGateway, List<Duration>)> gatewayWith(
  Future<JsonReply> Function(Uri uri, String method) api,
) async {
  final waits = <Duration>[];
  final gateway = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    sleeper: (d) async => waits.add(d),
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      return api(uri, method);
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return (gateway, waits);
}

void main() {
  test('leitura recusada por sobrecarga (503/429) tenta de novo com espera crescente', () async {
    var calls = 0;
    final (gateway, waits) = await gatewayWith((uri, method) async {
      calls++;
      if (calls == 1) {
        return const JsonReply(503, {'message': 'Service Unavailable'});
      }
      if (calls == 2) {
        return const JsonReply(429, {'message': 'Too Many Requests'});
      }
      return const JsonReply(200, {'items': []});
    });
    expect(await gateway.request('/editions'), {'items': []});
    expect(calls, 3);
    expect(waits.length, 2);
    expect(waits[1] > waits[0] - const Duration(milliseconds: 300), isTrue);
  });

  test(
    'leitura desiste depois de 2 novas tentativas e mostra a falha',
    () async {
      var calls = 0;
      final (gateway, _) = await gatewayWith((uri, method) async {
        calls++;
        return const JsonReply(503, {'message': 'Service Unavailable'});
      });
      await expectLater(
        gateway.request('/editions'),
        throwsA(
          isA<IdentityIssue>().having(
            (e) => e.code,
            'code',
            'SERVICE_UNAVAILABLE',
          ),
        ),
      );
      expect(calls, 3);
    },
  );

  test('erro da aplicação (503 com código) não é repetido', () async {
    var calls = 0;
    final (gateway, _) = await gatewayWith((uri, method) async {
      calls++;
      return const JsonReply(503, {'code': 'CATALOG_INTEGRITY_FAILURE'});
    });
    await expectLater(
      gateway.request('/editions'),
      throwsA(isA<IdentityIssue>()),
    );
    expect(calls, 1);
  });

  test('escrita não é repetida pelo gateway', () async {
    var calls = 0;
    final (gateway, waits) = await gatewayWith((uri, method) async {
      calls++;
      return const JsonReply(503, {'message': 'Service Unavailable'});
    });
    await expectLater(
      gateway.request('/participations', method: 'POST', body: const {}),
      throwsA(isA<IdentityIssue>()),
    );
    expect(calls, 1);
    expect(waits, isEmpty);
  });

  test('no máximo 4 chamadas à API ao mesmo tempo', () async {
    var inFlight = 0, peak = 0;
    final (gateway, _) = await gatewayWith((uri, method) async {
      inFlight++;
      if (inFlight > peak) peak = inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      inFlight--;
      return const JsonReply(200, {});
    });
    await Future.wait([
      for (var i = 0; i < 20; i++) gateway.request('/editions/$i'),
    ]);
    expect(peak, IdentityGateway.maxInFlight);
  });
}
