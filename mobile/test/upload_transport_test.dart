import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/identity_gateway.dart';

void main() {
  test(
    'putBytes informa Content-Length e nao usa Transfer-Encoding chunked',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String, String?>{};
      server.listen((request) async {
        seen['length'] = request.headers.value('content-length');
        seen['encoding'] = request.headers.value('transfer-encoding');
        seen['type'] = request.headers.value('content-type');
        await request.drain<void>();
        request.response.statusCode = 200;
        await request.response.close();
      });
      final client = HttpClient();
      final status = await putBytes(
        client,
        Uri.parse('http://127.0.0.1:${server.port}/x'),
        'PUT',
        {'Content-Type': 'image/jpeg'},
        List<int>.filled(300000, 7),
      );
      client.close(force: true);
      await server.close(force: true);
      expect(status, 200);
      expect(seen['length'], '300000');
      expect(seen['encoding'], isNull);
      expect(seen['type'], 'image/jpeg');
    },
  );
}
