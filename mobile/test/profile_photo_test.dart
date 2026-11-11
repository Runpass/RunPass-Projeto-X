import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/friends.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/my_races.dart';
import 'package:runpass/profile_photo.dart';

final onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<(IdentityGateway, List<String>, List<Map<String, dynamic>?>)> setup({
  required bool hasPhoto,
}) async {
  final calls = <String>[];
  final patches = <Map<String, dynamic>?>[];
  final gateway = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    byteTransport: (uri, method, headers, bytes) async => 200,
    transport: (uri, method, headers, body) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      calls.add('$method ${uri.path}');
      if (uri.path == '/uploads') {
        return const JsonReply(201, {
          'uploadId': 'up1',
          'uploadUrl': 'https://signed.example/up1',
          'uploadMethod': 'PUT',
          'uploadHeaders': {'Content-Type': 'image/png'},
        });
      }
      if (uri.path == '/uploads/up1/finalize') {
        return const JsonReply(200, {
          'uploadId': 'up1',
          'state': 'valid',
          'imageReference': 'img_new',
        });
      }
      if (method == 'PATCH') {
        patches.add(body);
        return const JsonReply(200, {'id': 'u1', 'version': 4});
      }
      if (uri.path == '/me') {
        return JsonReply(200, {
          'id': 'u1',
          'displayName': 'Eu',
          'username': 'eu',
          'version': 3,
          if (hasPhoto) 'photoReference': 'img_old',
        });
      }
      return const JsonReply(200, {'items': []});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return (gateway, calls, patches);
}

/// PNG retangular (largura != altura) para testar que a rotacao troca as
/// dimensoes; cada metade tem uma cor para checar o sentido do giro.
Future<Uint8List> rectanglePng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width / 2, height.toDouble()),
    Paint()..color = const Color(0xffff0000),
  );
  canvas.drawRect(
    Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()),
    Paint()..color = const Color(0xff0000ff),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('trocar a foto: escolhe a origem, envia e grava a referencia', (
    tester,
  ) async {
    final (gateway, calls, patches) = await setup(hasPhoto: false);
    PhotoChoice? asked;
    await tester.pumpWidget(
      MaterialApp(
        home: RunnerProfileScreen(
          gateway: gateway,
          photoPicker: (context, choice) async {
            asked = choice;
            return onePixelPng;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change-profile-photo')));
    await tester.pumpAndSettle();
    // Sem foto ainda, nao ha "Remover foto".
    expect(find.byKey(const Key('photo-remove')), findsNothing);
    await tester.tap(find.byKey(const Key('photo-camera')));
    await tester.pumpAndSettle();
    expect(asked, PhotoChoice.camera);
    expect(calls, contains('POST /uploads'));
    expect(patches, [
      {'expectedVersion': 3, 'photoReference': 'img_new'},
    ]);
  });

  testWidgets('remover a foto pede confirmacao e grava nulo', (tester) async {
    final (gateway, _, patches) = await setup(hasPhoto: true);
    await tester.pumpWidget(
      MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change-profile-photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-remove')));
    await tester.pumpAndSettle();
    expect(find.text('Remover a foto de perfil?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-remove-photo')));
    await tester.pumpAndSettle();
    expect(patches, [
      {'expectedVersion': 3, 'photoReference': null},
    ]);
  });

  testWidgets('desistir da escolha nao envia nada', (tester) async {
    final (gateway, calls, patches) = await setup(hasPhoto: true);
    await tester.pumpWidget(
      MaterialApp(
        home: RunnerProfileScreen(
          gateway: gateway,
          photoPicker: (context, choice) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change-profile-photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-gallery')));
    await tester.pumpAndSettle();
    expect(patches, isEmpty);
    expect(calls, isNot(contains('POST /uploads')));
  });

  testWidgets('botao Banner nao encosta nos icones de sino e configuracoes', (
    tester,
  ) async {
    // Aparelho com ilha dinamica: area segura do topo grande.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final (gateway, _, _) = await setup(hasPhoto: true);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(393, 852),
          padding: EdgeInsets.only(top: 59),
        ),
        child: MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
      ),
    );
    await tester.pumpAndSettle();
    final banner = tester.getRect(find.byKey(const Key('change-banner')));
    final gear = tester.getRect(find.byKey(const Key('open-settings')));
    expect(banner.overlaps(gear), isFalse);
    expect(banner.top - gear.bottom, greaterThanOrEqualTo(12));
  });

  testWidgets(
    'seguidores e seguindo ficam abaixo do banner e ao lado da foto',
    (tester) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (gateway, _, _) = await setup(hasPhoto: true);
      await tester.pumpWidget(
        MaterialApp(home: RunnerProfileScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      final banner = tester.getRect(find.byKey(const Key('profile-banner')));
      final counts = tester.getRect(find.byKey(const Key('profile-counts')));
      final avatar = tester.getRect(find.byType(ProfileAvatar).first);
      expect(
        counts.top,
        greaterThanOrEqualTo(banner.bottom),
      ); // nunca sobre o banner
      expect(counts.left, greaterThan(avatar.right)); // ao lado da foto
      expect(counts.center.dy, greaterThan(banner.bottom));
    },
  );
}
