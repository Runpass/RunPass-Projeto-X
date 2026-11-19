import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:runpass/home_screen.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/main.dart';
import 'package:runpass/my_races.dart';
import 'package:runpass/post_card.dart';
import 'package:runpass/runpass_theme.dart';
import 'package:runpass/settings.dart';
import 'package:share_plus/share_plus.dart';

/// Caminho temporario de verdade (sem plugin nativo) para o compartilhamento
/// gravar o arquivo nos testes.
class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

IdentityGateway gatewayWith(JsonTransport handler, {MemoryTokenStore? store}) =>
    IdentityGateway(
      cognito: Uri.parse('https://cognito.example'),
      api: Uri.parse('https://api.example'),
      clientId: 'synthetic',
      tokenStore: store,
      transport: handler,
    );

void main() {
  group('manter conectado', () {
    test('guarda so o token de renovacao e renova o acesso depois', () async {
      final store = MemoryTokenStore();
      var access = 'a1';
      final gateway = gatewayWith((uri, method, headers, body) async {
        if (uri.host == 'cognito.example') {
          if (body!['AuthFlow'] == 'REFRESH_TOKEN_AUTH') {
            expect(body['AuthParameters']['REFRESH_TOKEN'], 'r1');
            access = 'a2';
            return JsonReply(200, {
              'AuthenticationResult': {'AccessToken': access},
            });
          }
          return const JsonReply(200, {
            'AuthenticationResult': {'AccessToken': 'a1', 'RefreshToken': 'r1'},
          });
        }
        return const JsonReply(200, {'ok': true});
      }, store: store);
      await gateway.signIn('a@x.test', 'senha', keepSignedIn: true);
      expect(store.value, 'r1');
      // App reaberto: outro gateway com o mesmo armazenamento volta sem senha.
      final reopened = gatewayWith((uri, method, headers, body) async {
        expect(body!['AuthFlow'], 'REFRESH_TOKEN_AUTH');
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'a3'},
        });
      }, store: store);
      expect(reopened.signedIn, isFalse);
      expect(await reopened.restoreSession(), isTrue);
      expect(reopened.signedIn, isTrue);
    });

    test('sem marcar "manter conectado" nada fica guardado', () async {
      final store = MemoryTokenStore()..value = 'velho';
      final gateway = gatewayWith((uri, method, headers, body) async {
        return const JsonReply(200, {
          'AuthenticationResult': {'AccessToken': 'a1', 'RefreshToken': 'r1'},
        });
      }, store: store);
      await gateway.signIn('a@x.test', 'senha');
      expect(store.value, isNull);
    });

    test('acesso expirado (401) renova uma vez e repete a chamada', () async {
      final store = MemoryTokenStore();
      final seen = <String>[];
      var first = true;
      final gateway = gatewayWith((uri, method, headers, body) async {
        if (uri.host == 'cognito.example') {
          if (body!['AuthFlow'] == 'REFRESH_TOKEN_AUTH') {
            return const JsonReply(200, {
              'AuthenticationResult': {'AccessToken': 'novo'},
            });
          }
          return const JsonReply(200, {
            'AuthenticationResult': {
              'AccessToken': 'velho',
              'RefreshToken': 'r1',
            },
          });
        }
        seen.add(headers['Authorization']!);
        if (first) {
          first = false;
          return const JsonReply(401, {});
        }
        return const JsonReply(200, {'ok': true});
      }, store: store);
      await gateway.signIn('a@x.test', 'senha', keepSignedIn: true);
      expect((await gateway.request('/me'))['ok'], true);
      expect(seen, ['Bearer velho', 'Bearer novo']);
      expect(gateway.signedIn, isTrue);
    });

    test('token recusado limpa o armazenamento e sair tambem', () async {
      final store = MemoryTokenStore()..value = 'revogado';
      final gateway = gatewayWith((uri, method, headers, body) async {
        return const JsonReply(400, {'__type': 'NotAuthorizedException'});
      }, store: store);
      expect(await gateway.restoreSession(), isFalse);
      expect(store.value, isNull);
      store.value = 'outro';
      await gateway.forgetSession();
      expect(store.value, isNull);
    });

    testWidgets('app reaberto com sessao guardada entra direto no Inicio', (
      tester,
    ) async {
      final store = MemoryTokenStore()..value = 'r1';
      final gateway = gatewayWith((uri, method, headers, body) async {
        if (uri.host == 'cognito.example') {
          return const JsonReply(200, {
            'AuthenticationResult': {'AccessToken': 'a'},
          });
        }
        if (uri.path == '/me') {
          return const JsonReply(200, {
            'id': 'u',
            'displayName': 'Eu',
            'username': 'eu',
            'version': 3,
            'photoReference': 'img',
          });
        }
        if (uri.path == '/beta/status') {
          return const JsonReply(200, {
            'myStatus': 'admitted',
            'admissionsOpen': true,
          });
        }
        return const JsonReply(200, {'items': []});
      }, store: store);
      await tester.pumpWidget(MainApp(gateway: gateway));
      await tester.pumpAndSettle();
      expect(find.byType(RunPassHomeScreen), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('a tela de entrada tem a opcao Manter conectado', (
      tester,
    ) async {
      final gateway = gatewayWith(
        (uri, method, headers, body) async => const JsonReply(200, {}),
      );
      await tester.pumpWidget(MainApp(gateway: gateway));
      expect(find.byKey(const Key('keep-signed-in')), findsOneWidget);
      expect(find.text('Manter conectado'), findsOneWidget);
    });
  });

  group('compartilhar', () {
    setUpAll(() {
      PathProviderPlatform.instance = _FakePathProviderPlatform();
    });

    FeedEntry entry() => FeedEntry(
      postId: 'p1',
      author: 'Ana',
      username: 'ana',
      title: 'Corrida A',
      comment: 'Foi lindo',
      race: const RaceRecord({
        'id': 'p-race',
        'editionId': 'E1',
        'distanceId': '10k',
      }, null),
      mine: false,
      authorProfile: const {'id': 'ana', 'displayName': 'Ana'},
    );

    testWidgets(
      'abre a folha do sistema com texto e imagem (cartao desenhado sem foto)',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        ShareParams? sent;
        shareFunction = (params) async {
          sent = params;
          return const ShareResult('', ShareResultStatus.success);
        };
        shareCardBuilder = ({
          required title,
          required line,
          photoBytes,
        }) async => Uint8List.fromList([1, 2, 3]);
        addTearDown(() {
          shareFunction = (params) => SharePlus.instance.share(params);
          shareCardBuilder = buildShareCard;
        });
        final gateway = gatewayWith((uri, method, headers, body) async {
          if (uri.host == 'cognito.example') {
            return const JsonReply(200, {
              'AuthenticationResult': {'AccessToken': 'a'},
            });
          }
          return const JsonReply(404, {'code': 'IMAGE_NOT_AVAILABLE'});
        });
        await gateway.signIn('a@x.test', 's');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [PostCard(gateway: gateway, entry: entry())],
              ),
            ),
          ),
        );
        await tester.ensureVisible(find.byKey(const Key('share-p-race')));
        // A preparacao e assincrona (rede, imagem e escrita em arquivo real):
        // o toque e a espera precisam rodar no ciclo real de eventos, nao no
        // relogio falso do teste, senao o await do arquivo nunca resolve.
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('share-p-race')));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(sent, isNotNull);
        // Sem texto junto da imagem: apps da Meta (Instagram, Facebook) tratam
        // mal o envio combinado e caem para o modo so-texto.
        expect(sent!.text, isNull);
        expect(sent!.files, hasLength(1));
        expect(sent!.files!.single.mimeType, 'image/png');
      },
    );

    testWidgets('se o anexo falhar, tenta so com o texto', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <ShareParams>[];
      shareFunction = (params) async {
        calls.add(params);
        if (params.files != null) throw Exception('sem anexo');
        return const ShareResult('', ShareResultStatus.success);
      };
      shareCardBuilder = ({required title, required line, photoBytes}) async =>
          Uint8List.fromList([1]);
      addTearDown(() {
        shareFunction = (params) => SharePlus.instance.share(params);
        shareCardBuilder = buildShareCard;
      });
      final gateway = gatewayWith((uri, method, headers, body) async {
        if (uri.host == 'cognito.example') {
          return const JsonReply(200, {
            'AuthenticationResult': {'AccessToken': 'a'},
          });
        }
        return const JsonReply(404, {});
      });
      await gateway.signIn('a@x.test', 's');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [PostCard(gateway: gateway, entry: entry())],
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('share-p-race')));
      // A preparacao e assincrona (rede, imagem e escrita em arquivo real):
      // o toque e a espera precisam rodar no ciclo real de eventos.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('share-p-race')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(calls.last.files, isNull);
      expect(calls.last.text, contains('Corrida A'));
    });

    testWidgets(
      'buildShareCard (real): foto de ponta a ponta sem faixas pretas, nome no alto, informações e logo',
      (tester) async {
        await tester.runAsync(() async {
          // Foto de verdade (nao mockada) e QUADRADA: num quadro 4:5 ela precisa preencher tudo, sem faixas pretas.
          final recorder = ui.PictureRecorder();
          final tinyCanvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 4, 4));
          tinyCanvas.drawRect(
            const Rect.fromLTWH(0, 0, 4, 4),
            Paint()..color = const Color(0xffff0000),
          );
          final tinyImage = await recorder.endRecording().toImage(4, 4);
          final tinyData = await tinyImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final photo = tinyData!.buffer.asUint8List();

          Future<ui.Image> decode(Uint8List png) async =>
              (await (await ui.instantiateImageCodec(
                png,
              )).getNextFrame()).image;
          Future<Color> pixel(ui.Image image, int x, int y) async {
            final raw = (await image.toByteData())!;
            final i = (y * image.width + x) * 4;
            return Color.fromARGB(
              raw.getUint8(i + 3),
              raw.getUint8(i),
              raw.getUint8(i + 1),
              raw.getUint8(i + 2),
            );
          }

          final withPhoto = await decode(
            await buildShareCard(
              title: 'Corrida A',
              line: '10,0 km · 58min',
              photoBytes: photo,
            ),
          );
          expect(withPhoto.width, 1080);
          // Nome (190) + foto quadrada na proporção dela (1080) + rodapé com informações e logo (260).
          expect(withPhoto.height, 190 + 1080 + 260);
          // Os cantos e o meio da foto são da própria foto (vermelha): nenhuma faixa preta.
          for (final (x, y) in [
            (2, 200),
            (1077, 200),
            (540, 700),
            (2, 1260),
            (1077, 1260),
          ]) {
            final c = await pixel(withPhoto, x, y);
            expect(c.r, greaterThan(0.9), reason: 'pixel $x,$y');
            expect(c.g, lessThan(0.1), reason: 'pixel $x,$y');
          }

          // Foto na horizontal (2:1): o quadro acompanha a proporção, limitada a 1,91:1, sem cortar o resto.
          final wideRecorder = ui.PictureRecorder();
          Canvas(wideRecorder, const Rect.fromLTWH(0, 0, 8, 4)).drawRect(
            const Rect.fromLTWH(0, 0, 8, 4),
            Paint()..color = const Color(0xff0000ff),
          );
          final wideImage = await wideRecorder.endRecording().toImage(8, 4);
          final widePng = (await wideImage.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List();
          final wide = await decode(
            await buildShareCard(
              title: 'Corrida A',
              line: '5 km',
              photoBytes: widePng,
            ),
          );
          final wideHeight = (1080 / 1.91).roundToDouble().toInt();
          expect(wide.height, 190 + wideHeight + 260);
          final wideEdge = await pixel(wide, 2, 190 + wideHeight - 4);
          expect(
            wideEdge.b,
            greaterThan(0.9),
          ); // a foto vai até a borda de baixo do quadro

          // Sem foto e sem informações ainda gera a imagem (marcador no lugar da foto).
          final withoutPhoto = await decode(
            await buildShareCard(title: 'Corrida A', line: ''),
          );
          expect(withoutPhoto.width, 1080);
          expect(withoutPhoto.height, 190 + 1350 + 260); // sem foto, quadro 4:5
        });
      },
    );
  });

  group('modo escuro', () {
    testWidgets('a chave nas configuracoes liga o tema escuro do app', (
      tester,
    ) async {
      addTearDown(() => ThemeController.dark.value = false);
      final gateway = gatewayWith((uri, method, headers, body) async {
        return const JsonReply(200, {
          'id': 'u',
          'displayName': 'Eu',
          'username': 'eu',
          'version': 1,
        });
      });
      await tester.pumpWidget(MainApp(gateway: gateway));
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.light,
      );
      ThemeController.dark.value = true;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.dark,
      );
    });

    testWidgets('configuracoes tem a opcao Modo escuro', (tester) async {
      addTearDown(() => ThemeController.dark.value = false);
      final gateway = gatewayWith((uri, method, headers, body) async {
        return const JsonReply(200, {'id': 'u', 'version': 1});
      });
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dark-mode-switch')));
      await tester.pumpAndSettle();
      expect(ThemeController.dark.value, isTrue);
    });
  });
}
