import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/medal_scan.dart';

/// Postar foto e cadastrar medalha: a lista de corridas mostra as que já aconteceram. Dados fictícios [FICTICIA].
void main() {
  String day(int offset) {
    final d = DateTime.now().add(Duration(days: offset));
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> race(String id, int offset) => {
    'id': id,
    'name': '[FICTICIA] Corrida $id',
    'date': day(offset),
    'city': 'São Paulo',
    'state': 'SP',
    'status': offset > 0 ? 'upcoming' : 'past',
    'distances': [
      {'id': '5k', 'kilometers': 5},
    ],
  };

  testWidgets(
    'Postar foto: mostra as corridas que já aconteceram (as mais recentes primeiro) e nenhuma futura',
    (tester) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final queries = <Map<String, String>>[];
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
            return const JsonReply(200, {'id': 'me', 'state': 'SP'});
          }
          if (uri.path == '/editions') {
            queries.add(uri.queryParameters);
            return JsonReply(200, {
              'items': [
                race('antiga', -30),
                race('ontem', -1),
                race('hoje', 0),
                race('amanha', 1),
              ],
            });
          }
          return const JsonReply(200, {'items': []});
        },
      );
      await gateway.signIn('synthetic@example.test', 'synthetic');
      await tester.pumpWidget(
        MaterialApp(
          home: MedalScanScreen(
            gateway: gateway,
            postPhotos: const [
              [0xff, 0xd8, 0xff, 0xd9],
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(queries.single['dateTo'], day(0));
      expect(queries.single['state'], 'SP');
      for (final id in ['hoje', 'ontem', 'antiga']) {
        expect(find.byKey(Key('medal-match-$id')), findsOneWidget);
      }
      expect(find.byKey(const Key('medal-match-amanha')), findsNothing);
      double top(String id) =>
          tester.getTopLeft(find.byKey(Key('medal-match-$id'))).dy;
      expect(top('hoje'), lessThan(top('ontem')));
      expect(top('ontem'), lessThan(top('antiga')));
    },
  );
}
