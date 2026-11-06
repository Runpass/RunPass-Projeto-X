import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/my_races.dart';

Future<IdentityGateway> gatewayWith(JsonTransport handler) async {
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
      return handler(uri, method, headers, body);
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return gateway;
}

void main() {
  testWidgets(
    'MedalPhoto asks for the signed link and falls back to the trophy',
    (tester) async {
      final paths = <String>[];
      final gateway = await gatewayWith((uri, method, headers, body) async {
        paths.add(uri.path);
        return const JsonReply(404, {'code': 'IMAGE_NOT_AVAILABLE'});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: MedalPhoto(gateway: gateway, participationId: 'p-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(paths, ['/participations/p-1/image']);
      expect(find.byType(MedalArt), findsOneWidget);
    },
  );

  testWidgets('MedalPhoto shows the image when the server returns a link', (
    tester,
  ) async {
    final gateway = await gatewayWith((uri, method, headers, body) async {
      return const JsonReply(200, {
        'url': 'https://signed.example/photo.jpg',
        'contentType': 'image/jpeg',
        'expiresAt': '2099-01-01T00:00:00Z',
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MedalPhoto(gateway: gateway, participationId: 'p-2'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('MedalPhoto without a participation id makes no request', (
    tester,
  ) async {
    var calls = 0;
    final gateway = await gatewayWith((uri, method, headers, body) async {
      calls++;
      return const JsonReply(200, {});
    });
    await tester.pumpWidget(
      MaterialApp(home: MedalPhoto(gateway: gateway, participationId: null)),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(MedalArt), findsOneWidget);
  });
}
