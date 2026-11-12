import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/catalog_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/organizer_post.dart';

Map<String, dynamic> edition(Map<String, dynamic> extra) => {
  'id': 'E1',
  'name': '[FICTICIA] Corrida do Organizador',
  'date': '2026-09-01',
  'city': 'São Paulo',
  'state': 'SP',
  'status': 'past',
  'version': 1,
  'distances': [
    {'id': '10k', 'kilometers': 10},
  ],
  ...extra,
};

Future<IdentityGateway> gatewayFor(Map<String, dynamic> body) async {
  final gateway = IdentityGateway(
    cognito: Uri.parse('https://cognito.example'),
    api: Uri.parse('https://api.example'),
    clientId: 'synthetic',
    transport: (uri, method, headers, payload) async {
      if (uri.host == 'cognito.example') {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'synthetic'},
        });
      }
      if (uri.path == '/editions/E1') return JsonReply(200, body);
      if (uri.path == '/editions/E1/photos') {
        return const JsonReply(200, {'items': [], 'total': 0});
      }
      return const JsonReply(200, {'items': [], 'total': 0});
    },
  );
  await gateway.signIn('synthetic@example.test', 'synthetic');
  return gateway;
}

Future<List<({String network, Uri uri})>> openPhotos(
  WidgetTester tester,
  Map<String, dynamic> extra, {
  OEmbedFetcher? fetcher,
}) async {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final asked = <({String network, Uri uri})>[];
  final gateway = await gatewayFor(edition(extra));
  await tester.pumpWidget(
    MaterialApp(
      home: EditionScreen(
        gateway: gateway,
        editionId: 'E1',
        oembedFetcher:
            fetcher ??
            (ref) async {
              asked.add(ref);
              return '<blockquote>embed sintético</blockquote>';
            },
        embedBuilder: (context, html, network) =>
            Text('EMBED[$network]: $html', key: const Key('fake-embed')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Fotos'));
  await tester.pumpAndSettle();
  return asked;
}

void main() {
  test('só posts, reels e vídeos públicos das redes valem como post do organizador', () {
    expect(
      organizerPostRef('https://www.instagram.com/p/AbC123xyz/')?.network,
      'instagram',
    );
    expect(
      organizerPostRef('https://instagram.com/reel/Cx9_aB-12/')?.network,
      'instagram',
    );
    expect(
      organizerPostRef(
        'https://www.facebook.com/corridaexemplo/posts/1234567890123',
      )?.network,
      'facebook',
    );
    expect(
      organizerPostRef('https://www.facebook.com/reel/1234567890')?.network,
      'facebook',
    );
    for (final bad in <Object?>[
      null,
      42,
      '',
      'https://www.instagram.com/corrida_exemplo/', // perfil não é post
      'http://www.instagram.com/p/AbC123xyz/', // sem https
      'https://exemplo.org/p/AbC123xyz/',
      'https://instagram.com.malicioso.invalid/p/AbC123xyz/',
      'https://user:senha@www.instagram.com/p/AbC123xyz/',
      'https://www.facebook.com/corridaexemplo',
      'javascript:alert(1)',
    ]) {
      expect(organizerPostRef(bad), isNull, reason: '$bad');
    }
  });

  test('o oEmbed oficial usa o endpoint certo de cada rede, sem token', () {
    final ig = oembedEndpoint(
      organizerPostRef('https://www.instagram.com/p/AbC123xyz/')!,
    );
    expect(ig.host, 'graph.facebook.com');
    expect(ig.path, '/v25.0/instagram_oembed');
    expect(ig.queryParameters['url'], 'https://www.instagram.com/p/AbC123xyz/');
    expect(ig.queryParameters.containsKey('access_token'), isFalse);
    expect(
      oembedEndpoint(
        organizerPostRef(
          'https://www.facebook.com/pagina.exemplo/posts/1234567890',
        )!,
      ).path,
      '/v25.0/oembed_post',
    );
    expect(
      oembedEndpoint(
        organizerPostRef('https://www.facebook.com/reel/1234567890')!,
      ).path,
      '/v25.0/oembed_video',
    );
  });

  testWidgets(
    'a aba Fotos mostra "Do organizador" com o embed do post aprovado',
    (tester) async {
      final asked = await openPhotos(tester, {
        'organizerPostUrl': 'https://www.instagram.com/p/AbC123xyz/',
      });
      expect(find.byKey(const Key('organizer-post')), findsOneWidget);
      expect(find.text('Do organizador · Instagram'), findsOneWidget);
      expect(find.byKey(const Key('fake-embed')), findsOneWidget);
      expect(find.textContaining('não copia nem guarda'), findsOneWidget);
      expect(
        asked.single.uri.toString(),
        'https://www.instagram.com/p/AbC123xyz/',
      );
      // Sem fotos, a aba ainda explica.
      expect(
        find.text('As fotos desta prova aparecerão aqui.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('sem post aprovado, ou com endereço inválido, nada aparece', (
    tester,
  ) async {
    await openPhotos(tester, {});
    expect(find.byKey(const Key('organizer-post')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await openPhotos(tester, {
      'organizerPostUrl': 'https://exemplo.org/p/AbC123xyz/',
    });
    expect(find.byKey(const Key('organizer-post')), findsNothing);
  });

  testWidgets(
    'se a Meta não entregar o embed, mostra o aviso e o link para abrir o post',
    (tester) async {
      final opened = <Uri>[];
      final original = organizerLinkOpener;
      organizerLinkOpener = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => organizerLinkOpener = original);
      await openPhotos(tester, {
        'organizerPostUrl': 'https://www.instagram.com/reel/Cx9_aB-12/',
      }, fetcher: (ref) async => null);
      expect(find.byKey(const Key('organizer-post-failed')), findsOneWidget);
      expect(find.byKey(const Key('fake-embed')), findsNothing);
      await tester.tap(find.byKey(const Key('organizer-post-open')));
      await tester.pump();
      expect(
        opened.single.toString(),
        'https://www.instagram.com/reel/Cx9_aB-12/',
      );
    },
  );
}
