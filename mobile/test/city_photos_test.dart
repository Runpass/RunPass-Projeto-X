import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runpass/city_photos.dart';
import 'package:runpass/edition_cards.dart';
import 'package:runpass/identity_gateway.dart';
import 'package:runpass/settings.dart';

import 'catalog_test.dart' show entry, signed;

void main() {
  test('foto da cidade só para SP, sem acento nem caixa, e nunca inventa', () {
    expect(
      cityPhotoFor({'city': 'São Paulo', 'state': 'SP'})?.title,
      'Parque Ibirapuera',
    );
    expect(cityPhotoFor({'city': 'SAO PAULO', 'state': 'sp'}), isNotNull);
    expect(cityPhotoFor({'city': 'Guarujá', 'state': 'SP'}), isNotNull);
    // Outro estado, cidade sem foto ou sem cidade: sem foto.
    expect(cityPhotoFor({'city': 'São Paulo', 'state': 'RJ'}), isNull);
    expect(cityPhotoFor({'city': 'Campinas', 'state': 'SP'}), isNull);
    expect(
      cityPhotoFor({'city': 'Bertioga', 'state': 'SP'})?.isIllustration,
      isTrue,
    );
    expect(cityPhotoFor({'state': 'SP'}), isNull);
  });

  test(
    'toda foto tem licença livre sem crédito obrigatório e arquivo próprio',
    () {
      expect(cityPhotoList.where((p) => !p.isIllustration), hasLength(28));
      expect(cityPhotoList.where((p) => p.isIllustration), hasLength(10));
      for (final photo in cityPhotoList) {
        expect(
          photo.isIllustration ||
              photo.license == 'CC0 1.0' ||
              photo.license == 'Domínio público',
          isTrue,
          reason: photo.city,
        );
        expect(photo.author, isNotEmpty);
        if (!photo.isIllustration) {
          expect(photo.sourceUrl, startsWith('https://commons.wikimedia.org/'));
        }
        expect(photo.asset, startsWith('assets/cidades/'));
      }
    },
  );

  testWidgets('cartão sem banner usa a foto da cidade, sem texto por cima', (
    tester,
  ) async {
    final gateway = await signed(
      (uri, method, headers, body) async => const JsonReply(200, {}),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditionCompactCard(
            gateway: gateway,
            edition: {
              ...entry('A'),
              'id': 'EA',
              'city': 'Jundiaí',
              'state': 'SP',
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('race-art-photo')), findsOneWidget);
    // Foto limpa: nenhum texto por cima (nem cidade, nem local, nem rótulo).
    expect(find.byKey(const Key('race-art-city')), findsNothing);
    expect(find.byKey(const Key('race-art-venue')), findsNothing);
    expect(find.byKey(const Key('race-art-tag')), findsNothing);
    expect(find.text('foto da cidade'), findsNothing);
    expect(find.text('arte do app'), findsNothing);
    // A data fica num selo sobre a foto.
    expect(find.byKey(const Key('date-chip-EA')), findsOneWidget);
  });

  testWidgets(
    'cidade sem foto ganha a capa genérica: nenhuma corrida fica sem imagem',
    (tester) async {
      final gateway = await signed(
        (uri, method, headers, body) async => const JsonReply(200, {}),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditionCompactCard(
              gateway: gateway,
              edition: {
                ...entry('A'),
                'id': 'EA',
                'city': 'Campinas',
                'state': 'SP',
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('race-art-photo')), findsOneWidget);
    },
  );

  group('capa da corrida [FICTICIA]', () {
    String asset(Map<String, dynamic> e) => coverPhotoFor(e).asset;
    test('corrida noturna: foto noturna da capital, genérica fora dela', () {
      expect(
        asset({'name': 'Night Run Teste', 'city': 'São Paulo', 'state': 'SP'}),
        'assets/cidades/sp-noite.jpg',
      );
      expect(
        asset({
          'name': 'Corrida Noturna Teste',
          'city': 'Santos',
          'state': 'SP',
        }),
        'assets/cidades/generica-noite.jpg',
      );
    });
    test('capital: o ponto pelo local ou pelo nome da prova', () {
      expect(
        asset({
          'name': 'Corrida Teste',
          'venue': 'Praça Charles Miller',
          'city': 'São Paulo',
          'state': 'SP',
        }),
        'assets/cidades/sp-pacaembu.jpg',
      );
      expect(
        asset({
          'name': 'Tricolor Run Teste',
          'city': 'São Paulo',
          'state': 'SP',
        }),
        'assets/cidades/sp-morumbi.jpg',
      );
      expect(
        asset({
          'name': 'Corrida Novo Rio Pinheiros Teste',
          'city': 'Sao Paulo',
          'state': 'SP',
        }),
        'assets/cidades/sp-ponte-estaiada.jpg',
      );
      expect(
        asset({
          'name': 'Corrida Teste',
          'venue': 'Parque Villa-Lobos',
          'city': 'São Paulo',
          'state': 'SP',
        }),
        'assets/cidades/sp-villa-lobos.jpg',
      );
    });
    test('capital sem local: uma das fotos da capital, sempre a mesma', () {
      final e = {
        'id': 'E-FICTICIA',
        'name': 'Corrida Teste',
        'city': 'São Paulo',
        'state': 'SP',
      };
      expect(spDefaultPhotos.map((p) => p.asset), contains(asset(e)));
      expect(asset(e), asset(Map.of(e)));
    });
    test('fora da capital: a foto da cidade, ou a genérica do tipo', () {
      expect(
        asset({'name': 'Corrida Teste', 'city': 'Jundiaí', 'state': 'SP'}),
        'assets/cidades/jundiai.jpg',
      );
      expect(
        asset({'name': 'Corrida Teste', 'city': 'Campinas', 'state': 'SP'}),
        'assets/cidades/generica-rua.jpg',
      );
      expect(
        asset({'name': 'Trail Run Teste', 'city': 'Campinas', 'state': 'SP'}),
        'assets/cidades/generica-trilha.jpg',
      );
      expect(
        asset({'name': 'Corrida Teste', 'city': 'São Paulo', 'state': 'RJ'}),
        'assets/cidades/generica-rua.jpg',
      );
    });
    test('toda imagem tem arquivo no projeto', () {
      for (final photo in allCoverPhotos) {
        expect(File(photo.asset).existsSync(), isTrue, reason: photo.asset);
      }
    });
  });

  testWidgets('créditos das fotos listam autor e licença de cada cidade', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 9000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: PhotoCreditsScreen()));
    for (final photo in allCoverPhotos) {
      final tile = find.byKey(Key('photo-credit-${photo.asset}'));
      expect(tile, findsOneWidget);
      expect(
        find.descendant(
          of: tile,
          matching: find.textContaining(
            photo.isIllustration
                ? photo.license
                : 'Foto: ${photo.author} · ${photo.license}',
          ),
        ),
        findsOneWidget,
        reason: photo.city,
      );
    }
  });
}
