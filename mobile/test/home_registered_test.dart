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
}
