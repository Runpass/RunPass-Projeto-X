import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';

void main() {
  test(
    'o corpo JSON chega ao servidor em UTF-8, com acentos e emojis',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      List<int>? received;
      String? contentType;
      server.listen((request) async {
        contentType = request.headers.contentType?.toString();
        received = await request.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true}));
        await request.response.close();
      });
      const text = 'Parabéns, ação! 🎉 São Paulo – “ótimo”';
      final reply = await sendJson(
        Uri.parse('http://127.0.0.1:${server.port}/x'),
        'POST',
        {'Content-Type': 'application/json'},
        {'text': text},
      );
      await server.close(force: true);
      expect(reply.status, 200);
      expect(contentType, contains('utf-8'));
      expect((jsonDecode(utf8.decode(received!)) as Map)['text'], text);
    },
  );

  test('o Content-Type do Cognito (x-amz-json-1.1) nao e trocado', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? contentType;
    server.listen((request) async {
      contentType = request.headers.value('content-type');
      await request.drain<void>();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true}));
      await request.response.close();
    });
    await sendJson(
      Uri.parse('http://127.0.0.1:${server.port}/'),
      'POST',
      {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth',
      },
      {'ClientId': 'x'},
    );
    await server.close(force: true);
    expect(contentType, startsWith('application/x-amz-json-1.1'));
  });
}
