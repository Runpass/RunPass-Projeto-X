import 'package:flutter/material.dart';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/pending_requests.dart';

Map<String, dynamic> request(String id, String status, {String? kind}) => {
  'id': id,
  'status': status,
  'version': 1,
  'kind': ?kind,
  'details': {
    'name': 'Corrida $id',
    'date': '2027-03-14',
    'city': 'São Paulo',
    'state': 'SP',
    'distanceKm': 10,
  },
};

Future<IdentityGateway> gateway(List<Map<String, dynamic>> items) async {
  final g = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      if (uri.path == '/editions/E1') {
        return const JsonReply(200, {
          'id': 'E1',
          'name': '[FICTICIA] Corrida',
          'date': '2026-09-22',
          'city': 'São Paulo',
          'state': 'SP',
          'status': 'past',
          'version': 1,
          'distances': [
            {'id': '5k', 'kilometers': 5},
          ],
        });
      }
      return JsonReply(200, {'items': items});
    },
  );
  await g.signIn('synthetic@example.test', 'synthetic');
  return g;
}

final onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  test(
    'só as sugestões de corrida ainda sem decisão aparecem para a pessoa',
    () async {
      final found = await loadPendingRequests(
        await gateway([
          request('a', 'pending'),
          request('b', 'awaiting_load'),
          request('c', 'approved'),
          request('d', 'rejected'),
          request('e', 'linked', kind: 'banner'),
          request('f', 'pending', kind: 'banner'),
        ]),
      );
      expect([for (final r in found) r['id']], ['a', 'b']);
    },
  );

  testWidgets(
    'a sugestão em análise aparece só para mim, cinza e com cadeado',
    (tester) async {
      final g = await gateway([request('a', 'pending')]);
      final found = await loadPendingRequests(g);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PendingRequestsSection(gateway: g, requests: found),
          ),
        ),
      );
      expect(find.text('Minhas sugestões em análise'), findsOneWidget);
      expect(find.text('Corrida a'), findsOneWidget);
      expect(
        find.textContaining('Em análise pela equipe · só você vê'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      // sem sugestões, a seção não ocupa espaço
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PendingRequestsSection(gateway: g, requests: const []),
          ),
        ),
      );
      expect(find.byKey(const Key('pending-requests')), findsNothing);
    },
  );

  test(
    'sem banner meu esperando decisão nesta corrida, nada provisório aparece',
    () async {
      final g = await gateway([
        {...request('a', 'approved'), 'linkedEditionId': 'outra'},
        {
          ...request('b', 'linked'),
          'linkedEditionId': 'E1',
          'bannerState': 'dismissed', // já decidido: some
          'details': {'name': 'x', 'imageReference': 'img_x'},
        },
        {
          ...request('c', 'linked'),
          'linkedEditionId': 'E1',
          'details': {'name': 'sem imagem'},
        },
      ]);
      expect(await loadProvisionalBanner(g, 'E1'), isNull);
    },
  );

  testWidgets(
    'meu banner em análise aparece na corrida só para mim, com o aviso',
    (tester) async {
      final g = await gateway([]);
      Future<void> open(
        Future<List<int>?> Function(IdentityGateway, String) loader,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: EditionScreen(
              gateway: g,
              editionId: 'E1',
              provisionalBannerLoader: loader,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open((_, _) async => onePixelPng);
      expect(find.byKey(const Key('hero-provisional')), findsOneWidget);
      expect(find.byKey(const Key('hero-provisional-note')), findsOneWidget);
      // Sem sugestão minha esperando decisão: nada provisório (tela nova, sem o estado anterior).
      await tester.pumpWidget(const SizedBox());
      await open((_, _) async => null);
      expect(find.byKey(const Key('hero-provisional')), findsNothing);
      expect(find.byKey(const Key('hero-provisional-note')), findsNothing);
    },
  );
}
