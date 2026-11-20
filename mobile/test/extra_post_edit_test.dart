import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/extra_post_edit.dart';
import 'package:runpass/identity_gateway.dart';

import 'catalog_test.dart' show signed;

const jpeg = [0xff, 0xd8, 0xff, 0xd9];

/// Editar a publicação a mais: trocar, remover e incluir fotos gravam na hora. Dados fictícios [FICTICIA].
void main() {
  Future<(IdentityGateway, List<Map>)> setup() async {
    final patches = <Map>[];
    var uploads = 0;
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path == '/posts/x1' && method == 'GET') {
        return const JsonReply(200, {
          'id': 'x1',
          'version': 2,
          'postImageCount': 3,
          'morePostImageReferences': ['img_a', 'img_b'],
        });
      }
      if (uri.path == '/uploads') {
        uploads++;
        return JsonReply(201, {
          'uploadId': 'up$uploads',
          'uploadUrl': 'https://signed.example/up$uploads',
          'uploadMethod': 'PUT',
          'uploadHeaders': {'Content-Type': 'image/jpeg'},
        });
      }
      if (uri.path.endsWith('/finalize')) {
        return JsonReply(200, {
          'state': 'valid',
          'imageReference': 'img_new$uploads',
        });
      }
      if (uri.path == '/posts/x1/extra' && method == 'PATCH') {
        patches.add(Map.from(body! as Map));
        return JsonReply(200, {'version': 2 + patches.length});
      }
      return const JsonReply(404, {'code': 'IMAGE_NOT_AVAILABLE'});
    }, byteTransport: (uri, method, headers, bytes) async => 200);
    return (gateway, patches);
  }

  Future<void> open(WidgetTester tester, IdentityGateway gateway) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ExtraPostEditScreen(
          gateway: gateway,
          postId: 'x1',
          version: 2,
          photoSelector: (context) async => jpeg,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('trocar uma foto a mais grava a lista com a nova no lugar', (
    tester,
  ) async {
    final (gateway, patches) = await setup();
    await open(tester, gateway);
    expect(find.byKey(const Key('post-photo-thumb-2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('post-photo-thumb-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('post-photo-replace')));
    await tester.pumpAndSettle();
    expect(patches.single['morePostImageReferences'], ['img_new1', 'img_b']);
    expect(patches.single['expectedVersion'], 2);
  });

  testWidgets('remover uma foto a mais e incluir outra', (tester) async {
    final (gateway, patches) = await setup();
    await open(tester, gateway);
    await tester.tap(find.byKey(const Key('post-photo-thumb-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('post-photo-remove')));
    await tester.pumpAndSettle();
    expect(patches.last['morePostImageReferences'], ['img_a']);
    expect(find.byKey(const Key('post-photo-thumb-2')), findsNothing);
    await tester.tap(find.byKey(const Key('post-photo-add')));
    await tester.pumpAndSettle();
    expect(patches.last['morePostImageReferences'], ['img_a', 'img_new1']);
    expect(patches.last['expectedVersion'], 3);
  });

  testWidgets('trocar a capa grava a foto da publicação', (tester) async {
    final (gateway, patches) = await setup();
    await open(tester, gateway);
    await tester.tap(find.byKey(const Key('post-photo-thumb-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('post-photo-remove')), findsNothing);
    await tester.tap(find.byKey(const Key('post-photo-replace')));
    await tester.pumpAndSettle();
    expect(patches.single['postImageReference'], 'img_new1');
  });
}
