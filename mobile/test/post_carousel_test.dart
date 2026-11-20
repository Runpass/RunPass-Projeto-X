import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/my_races.dart';
import 'package:runpass/post_card.dart';

import 'catalog_test.dart' show signed;

import 'package:runpass/identity_gateway.dart';

/// Publicação com várias fotos no feed: carrossel com "1/3" e bolinhas; cada página pede a sua foto
/// (`?index=N`). Dados fictícios [FICTICIA].
void main() {
  FeedEntry entry(int count) => entryFromPost(
    {
      'id': 'p1',
      'author': {
        'id': 'ana',
        'displayName': 'Ana [FICTICIA]',
        'username': 'ana',
      },
      'participation': {'id': 'r1', 'editionId': 'E1', 'distanceId': '10k'},
      'hasPostImage': true,
      'postImageCount': count,
    },
    null,
    'eu',
  );

  test('endereço de cada foto: a capa sem índice, as outras com ?index=N', () {
    final e = entry(3);
    expect(e.photoCount, 3);
    expect(e.photoEndpointAt(0), '/participations/r1/post-image');
    expect(e.photoEndpointAt(2), '/participations/r1/post-image?index=2');
    expect(entry(9).photoCount, 5); // nunca mais de 5
  });

  testWidgets('carrossel: desliza entre as fotos e pede cada uma pelo índice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final asked = <String>[];
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path.endsWith('/post-image')) {
        asked.add(uri.queryParameters['index'] ?? '0');
      }
      return const JsonReply(404, {'code': 'IMAGE_NOT_AVAILABLE'});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [PostCard(gateway: gateway, entry: entry(3))],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PostPhotoCarousel), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('post-photo-pages')),
      const Offset(-700, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    expect(asked, containsAll(['0', '1']));
  });

  testWidgets('uma foto só: sem carrossel', (tester) async {
    final gateway = await signed(
      (uri, method, headers, body) async =>
          const JsonReply(404, {'code': 'IMAGE_NOT_AVAILABLE'}),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [PostCard(gateway: gateway, entry: entry(1))],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PostPhotoCarousel), findsNothing);
    expect(find.byType(MedalPhoto), findsWidgets);
  });

  testWidgets('compartilhar leva a foto do carrossel que está na tela', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final asked = <String>[];
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path.endsWith('/post-image')) {
        asked.add(uri.queryParameters['index'] ?? '0');
      }
      return const JsonReply(404, {'code': 'IMAGE_NOT_AVAILABLE'});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [PostCard(gateway: gateway, entry: entry(3))],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.drag(
        find.byKey(const Key('post-photo-pages')),
        const Offset(-700, 0),
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('3/3'), findsOneWidget);
    final state = tester.state(find.byType(PostCard)) as dynamic;
    expect(state.shownPhoto, 2);
    asked.clear();
    await tester.runAsync(() async {
      try {
        await state.shareImage();
      } on Object {
        // Sem a pasta temporária no teste, a gravação do arquivo falha; a foto já foi pedida antes.
      }
    });
    expect(asked, contains('2')); // a 3ª foto, a que está na tela
  });

  testWidgets('dois toques na foto curtem (e não descurtem)', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final likes = <String>[];
    final gateway = await signed((uri, method, headers, body) async {
      if (uri.path.endsWith('/like')) {
        likes.add(method);
        return const JsonReply(200, {});
      }
      return const JsonReply(404, {'code': 'IMAGE_NOT_AVAILABLE'});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [PostCard(gateway: gateway, entry: entry(1))],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final photo = find.byKey(const Key('post-photo-double-tap-p1'));
    await tester.tap(photo);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(photo);
    await tester.pump(const Duration(milliseconds: 100));
    expect(likes, ['PUT']);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byKey(const Key('double-tap-heart')),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity,
      1,
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // Já curtida: dois toques de novo não descurtem.
    await tester.tap(photo);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(photo);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(likes, ['PUT']);
  });
}
