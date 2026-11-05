import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/demo_transport.dart';
import 'package:runpass/identity_gateway.dart';

void main() {
  testWidgets('a race registered in the demo appears on the home screen', (
    tester,
  ) async {
    final demo = DemoTransport();
    final gateway = IdentityGateway(
      cognito: Uri.parse('https://cognito.demo.invalid'),
      api: Uri.parse('https://api.demo.invalid'),
      clientId: 'demo-not-a-real-client',
      transport: demo.call,
      byteTransport: demo.putBytes,
    );
    await gateway.signIn('demo@runpass.test', 'RunpassDemo123!');
    await gateway.request(
      '/me',
      method: 'PUT',
      body: {'displayName': 'Corredor Demo', 'username': 'corredor_demo'},
    );
    await gateway.request(
      '/beta/admissions',
      method: 'POST',
      body: {'birthDate': '1990-01-01', 'declaresAdult': true},
    );
    final draft = await gateway.request(
      '/participations',
      method: 'POST',
      body: {'editionId': 'demo-1', 'distanceId': '10k'},
    );
    final png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3];
    final image = await gateway.uploadImage(png, 'image/png');
    expect(image['state'], 'valid');
    final done = await gateway.request(
      '/participations/${draft['id']}/complete',
      method: 'POST',
      body: {
        'expectedVersion': draft['version'],
        'declaredCompleted': true,
        'ratings': {
          for (final key in [
            'organization',
            'course',
            'kit',
            'medal',
            'hydration',
            'facilities',
            'safety',
            'valueForMoney',
          ])
            key: 5,
        },
        'medalImageReference': image['imageReference'],
        'publishToFeed': true,
      },
    );
    expect(done['state'], 'completed');

    await tester.pumpWidget(
      MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    expect(find.text('concluiu Corrida de Demonstração 01'), findsOneWidget);
  });

  testWidgets('a private draft is listed on the home screen and reopens', (
    tester,
  ) async {
    final demo = DemoTransport();
    final gateway = IdentityGateway(
      cognito: Uri.parse('https://cognito.demo.invalid'),
      api: Uri.parse('https://api.demo.invalid'),
      clientId: 'demo-not-a-real-client',
      transport: demo.call,
      byteTransport: demo.putBytes,
    );
    await gateway.signIn('demo@runpass.test', 'RunpassDemo123!');
    await gateway.request(
      '/me',
      method: 'PUT',
      body: {'displayName': 'Corredor Demo', 'username': 'corredor_demo'},
    );
    await gateway.request(
      '/beta/admissions',
      method: 'POST',
      body: {'birthDate': '1990-01-01', 'declaresAdult': true},
    );
    final draft = await gateway.request(
      '/participations',
      method: 'POST',
      body: {'editionId': 'demo-1', 'distanceId': '10k'},
    );
    await tester.pumpWidget(
      MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Rascunhos em andamento'), findsOneWidget);
    await tester.tap(find.byKey(Key('draft-${draft['id']}')));
    await tester.pumpAndSettle();
    expect(find.text('Rascunho da participação'), findsOneWidget);
  });

  testWidgets('a draft can be deleted from the home screen', (tester) async {
    final demo = DemoTransport();
    final gateway = IdentityGateway(
      cognito: Uri.parse('https://cognito.demo.invalid'),
      api: Uri.parse('https://api.demo.invalid'),
      clientId: 'demo-not-a-real-client',
      transport: demo.call,
      byteTransport: demo.putBytes,
    );
    await gateway.signIn('demo@runpass.test', 'RunpassDemo123!');
    await gateway.request(
      '/me',
      method: 'PUT',
      body: {'displayName': 'Corredor Demo', 'username': 'corredor_demo'},
    );
    await gateway.request(
      '/beta/admissions',
      method: 'POST',
      body: {'birthDate': '1990-01-01', 'declaresAdult': true},
    );
    final draft = await gateway.request(
      '/participations',
      method: 'POST',
      body: {'editionId': 'demo-1', 'distanceId': '10k'},
    );
    await tester.pumpWidget(
      MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('delete-draft-${draft['id']}')));
    await tester.pumpAndSettle();
    expect(find.text('Excluir rascunho?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Excluir rascunho'));
    await tester.pumpAndSettle();
    expect(find.text('Rascunhos em andamento'), findsNothing);
  });

  testWidgets('future races are listed apart from drafts in progress', (
    tester,
  ) async {
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
        if (uri.path == '/me/participations') {
          return const JsonReply(200, {
            'items': [
              {
                'id': 'p-future',
                'editionId': 'F',
                'distanceId': '10k',
                'state': 'draft',
                'version': 1,
              },
              {
                'id': 'p-past',
                'editionId': 'P',
                'distanceId': '5k',
                'state': 'draft',
                'version': 1,
              },
            ],
          });
        }
        if (uri.path == '/editions/F' || uri.path == '/editions/P') {
          final future = uri.path.endsWith('F');
          return JsonReply(200, {
            'id': future ? 'F' : 'P',
            'name': future ? 'Prova Futura' : 'Prova Passada',
            'date': future ? '2999-01-01' : '2000-01-01',
            'city': 'São Paulo',
            'state': 'SP',
            'distances': [
              {'id': '5k', 'kilometers': 5},
              {'id': '10k', 'kilometers': 10},
            ],
            'status': future ? 'upcoming' : 'past',
            'version': 1,
          });
        }
        return const JsonReply(200, {'items': []});
      },
    );
    await gateway.signIn('synthetic@example.test', 'synthetic');
    await tester.pumpWidget(
      MaterialApp(home: RunPassHomeScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Minhas corridas futuras'), findsOneWidget);
    expect(find.text('Rascunhos em andamento'), findsOneWidget);
    expect(find.text('Prova Futura'), findsOneWidget);
    expect(find.text('Prova Passada'), findsOneWidget);
  });
}
